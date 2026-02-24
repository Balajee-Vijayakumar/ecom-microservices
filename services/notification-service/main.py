import os, json, asyncio, logging, smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from datetime import datetime
from typing import Optional
from contextlib import asynccontextmanager

import boto3
import aio_pika
import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("notification-service")

PROJECT  = os.getenv("PROJECT_NAME", "ecom-microservices")
ENV      = os.getenv("ENVIRONMENT",  "prod")
REGION   = os.getenv("AWS_REGION",   "us-east-2")
IS_LOCAL = os.getenv("APP_ENV", "production") in ("local", "test")

USER_SERVICE_URL = os.getenv("USER_SERVICE_URL", f"http://user-service.{PROJECT}-{ENV}.svc.cluster.local:3001")


# ─── Secrets ──────────────────────────────────────────────────────────────────
def get_secrets():
    if IS_LOCAL:
        return {
            "rabbitmq_url": os.getenv("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/"),
            "smtp_host":    os.getenv("SMTP_HOST",    "smtp.gmail.com"),
            "smtp_port":    int(os.getenv("SMTP_PORT", "587")),
            "smtp_user":    os.getenv("SMTP_USER",    "noreply@example.com"),
            "smtp_password": os.getenv("SMTP_PASSWORD", ""),
        }
    sm = boto3.client("secretsmanager", region_name=REGION)
    rmq  = json.loads(sm.get_secret_value(SecretId=f"{PROJECT}/{ENV}/app/rabbitmq")["SecretString"])
    smtp = json.loads(sm.get_secret_value(SecretId=f"{PROJECT}/{ENV}/app/smtp")["SecretString"])
    return {
        "rabbitmq_url":  rmq["url"],
        "smtp_host":     smtp["host"],
        "smtp_port":     int(smtp["port"]),
        "smtp_user":     smtp["user"],
        "smtp_password": smtp["password"],
    }

SECRETS = {}

# ─── Email Sender ─────────────────────────────────────────────────────────────
def send_email(to: str, subject: str, html_body: str) -> bool:
    try:
        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"]    = SECRETS["smtp_user"]
        msg["To"]      = to
        msg.attach(MIMEText(html_body, "html"))

        with smtplib.SMTP(SECRETS["smtp_host"], SECRETS["smtp_port"]) as s:
            s.ehlo()
            s.starttls()
            s.login(SECRETS["smtp_user"], SECRETS["smtp_password"])
            s.sendmail(SECRETS["smtp_user"], to, msg.as_string())
        logger.info(f"Email sent to {to}: {subject}")
        return True
    except Exception as e:
        logger.error(f"Email failed to {to}: {e}")
        return False

# ─── Email Templates ──────────────────────────────────────────────────────────
def tpl_order_created(order_id: str, total: float, items: list) -> str:
    items_html = "".join(
        f"<tr><td>{i.get('name','Product')}</td><td>{i.get('quantity',1)}</td><td>${float(i.get('price',0)):.2f}</td></tr>"
        for i in items
    )
    return f"""
    <html><body style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto">
    <h2 style="color:#2563eb">Order Confirmed! 🎉</h2>
    <p>Your order <strong>#{order_id[:8].upper()}</strong> has been placed successfully.</p>
    <table border="1" cellpadding="8" cellspacing="0" style="width:100%;border-collapse:collapse">
      <thead><tr style="background:#f3f4f6"><th>Item</th><th>Qty</th><th>Price</th></tr></thead>
      <tbody>{items_html}</tbody>
    </table>
    <p style="font-size:18px;margin-top:16px">Total: <strong>${total:.2f}</strong></p>
    <p>We'll notify you when your order ships.</p>
    <p style="color:#6b7280;font-size:12px">Thank you for shopping with us!</p>
    </body></html>"""

def tpl_order_status(order_id: str, status: str) -> str:
    icons = {"confirmed":"✅","processing":"🔄","shipped":"🚚","delivered":"📦","cancelled":"❌"}
    messages = {
        "confirmed":  "Your order has been confirmed and is being prepared.",
        "processing": "Your order is now being processed.",
        "shipped":    "Your order is on its way!",
        "delivered":  "Your order has been delivered. Enjoy!",
        "cancelled":  "Your order has been cancelled. Contact support if needed.",
    }
    icon = icons.get(status, "📋")
    msg  = messages.get(status, f"Order status updated to: {status}")
    return f"""
    <html><body style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto">
    <h2>Order Update {icon}</h2>
    <p>Order <strong>#{order_id[:8].upper()}</strong></p>
    <p style="font-size:16px">{msg}</p>
    <p style="color:#6b7280;font-size:12px">Questions? Contact our support team.</p>
    </body></html>"""

def tpl_welcome(name: str) -> str:
    return f"""
    <html><body style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto">
    <h2 style="color:#2563eb">Welcome, {name}! 👋</h2>
    <p>Your account has been created successfully.</p>
    <p>Start shopping now and enjoy our exclusive deals.</p>
    </body></html>"""

# ─── User Lookup ──────────────────────────────────────────────────────────────
async def get_user_email(user_id: str) -> Optional[str]:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            res = await client.get(f"{USER_SERVICE_URL}/users/{user_id}")
            if res.status_code == 200:
                return res.json().get("email")
    except Exception as e:
        logger.error(f"Failed to get user email for {user_id}: {e}")
    return None

# ─── Message Processor ────────────────────────────────────────────────────────
async def process_message(message: aio_pika.IncomingMessage):
    async with message.process():
        try:
            data = json.loads(message.body)
            event_type = data.get("eventType")
            payload    = data.get("data", {})
            logger.info(f"Processing event: {event_type}")

            if event_type == "ORDER_CREATED":
                user_id  = payload.get("userId")
                order_id = payload.get("orderId", "")
                total    = float(payload.get("totalAmount", 0))
                items    = payload.get("items", [])
                email    = await get_user_email(user_id)
                if email:
                    send_email(email, f"Order Confirmed #{order_id[:8].upper()}",
                               tpl_order_created(order_id, total, items))

            elif event_type == "ORDER_STATUS_UPDATED":
                order_id = payload.get("orderId", "")
                status   = payload.get("status", "")
                user_id  = payload.get("userId")
                if user_id:
                    email = await get_user_email(user_id)
                    if email:
                        send_email(email, f"Order {status.capitalize()} #{order_id[:8].upper()}",
                                   tpl_order_status(order_id, status))

            elif event_type == "USER_REGISTERED":
                email = payload.get("email")
                name  = payload.get("name", "Customer")
                if email:
                    send_email(email, "Welcome to EcomStore! 🎉", tpl_welcome(name))

        except Exception as e:
            logger.error(f"Error processing message: {e}")

# ─── RabbitMQ Consumer ────────────────────────────────────────────────────────
async def start_consumer():
    while True:
        try:
            conn    = await aio_pika.connect_robust(SECRETS["rabbitmq_url"])
            channel = await conn.channel()
            await channel.set_qos(prefetch_count=10)
            queue   = await channel.declare_queue("order_events", durable=True)
            await queue.consume(process_message)
            logger.info("Consuming from order_events queue")
            await asyncio.Future()  # run forever
        except Exception as e:
            logger.error(f"RabbitMQ error: {e}. Reconnecting in 5s...")
            await asyncio.sleep(5)

# ─── FastAPI App ──────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    global SECRETS
    SECRETS = get_secrets()
    asyncio.create_task(start_consumer())
    logger.info("Notification Service started")
    yield
    logger.info("Notification Service stopped")

app = FastAPI(title="Notification Service", version="1.0.0", lifespan=lifespan)

class NotificationRequest(BaseModel):
    to_email:          str
    subject:           str
    body:              str
    notification_type: str = "general"

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "notification-service", "timestamp": datetime.utcnow().isoformat()}

@app.post("/notify")
async def send_notification(req: NotificationRequest):
    success = send_email(to=req.to_email, subject=req.subject, html_body=req.body)
    if not success:
        raise HTTPException(status_code=500, detail="Failed to send notification")
    return {"message": "Notification sent", "to": req.to_email}

@app.post("/notify/welcome")
async def send_welcome(email: str, name: str):
    success = send_email(email, "Welcome to EcomStore! 🎉", tpl_welcome(name))
    if not success:
        raise HTTPException(status_code=500, detail="Failed to send welcome email")
    return {"message": "Welcome email sent"}
