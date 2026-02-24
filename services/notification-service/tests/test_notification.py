import pytest, os
os.environ["APP_ENV"]      = "test"
os.environ["RABBITMQ_URL"] = "amqp://localhost:5672"
os.environ["SMTP_HOST"]    = "smtp.gmail.com"
os.environ["SMTP_PORT"]    = "587"
os.environ["SMTP_USER"]    = "test@example.com"
os.environ["SMTP_PASSWORD"] = "testpass"

from unittest.mock import AsyncMock, patch, MagicMock
from httpx import AsyncClient, ASGITransport
from main import app, tpl_order_created, tpl_order_status, tpl_welcome, send_email

@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c

# ─── Health ───────────────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_health(client):
    res = await client.get("/health")
    assert res.status_code == 200
    assert res.json()["status"] == "healthy"
    assert res.json()["service"] == "notification-service"

# ─── Email Templates ──────────────────────────────────────────────────────────
def test_order_created_template():
    html = tpl_order_created("abc123", 99.99, [{"name": "Widget", "quantity": 2, "price": 49.99}])
    assert "abc123"[:8].upper() in html
    assert "99.99" in html
    assert "Widget" in html

def test_order_status_template_shipped():
    html = tpl_order_status("abc123", "shipped")
    assert "🚚" in html
    assert "on its way" in html

def test_order_status_template_delivered():
    html = tpl_order_status("abc123", "delivered")
    assert "📦" in html

def test_order_status_template_cancelled():
    html = tpl_order_status("abc123", "cancelled")
    assert "❌" in html

def test_welcome_template():
    html = tpl_welcome("John")
    assert "John" in html
    assert "Welcome" in html

# ─── Send Email ───────────────────────────────────────────────────────────────
def test_send_email_success():
    from main import SECRETS
    SECRETS.update({
        "smtp_host": "smtp.gmail.com", "smtp_port": 587,
        "smtp_user": "test@example.com", "smtp_password": "pass"
    })
    with patch("smtplib.SMTP") as mock_smtp:
        mock_server = MagicMock()
        mock_smtp.return_value.__enter__ = MagicMock(return_value=mock_server)
        mock_smtp.return_value.__exit__  = MagicMock(return_value=False)
        result = send_email("user@example.com", "Test Subject", "<p>Test</p>")
    assert result is True

def test_send_email_failure():
    from main import SECRETS
    SECRETS.update({"smtp_host": "smtp.gmail.com", "smtp_port": 587, "smtp_user": "t@e.com", "smtp_password": "x"})
    with patch("smtplib.SMTP", side_effect=Exception("SMTP error")):
        result = send_email("user@example.com", "Subject", "<p>Body</p>")
    assert result is False

# ─── POST /notify ─────────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_notify_endpoint_success(client):
    with patch("main.send_email", return_value=True):
        res = await client.post("/notify", json={
            "to_email": "user@example.com",
            "subject":  "Test",
            "body":     "<p>Hello</p>"
        })
    assert res.status_code == 200
    assert res.json()["message"] == "Notification sent"

@pytest.mark.anyio
async def test_notify_endpoint_failure(client):
    with patch("main.send_email", return_value=False):
        res = await client.post("/notify", json={
            "to_email": "user@example.com",
            "subject":  "Test",
            "body":     "<p>Hello</p>"
        })
    assert res.status_code == 500

# ─── POST /notify/welcome ─────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_welcome_endpoint(client):
    with patch("main.send_email", return_value=True):
        res = await client.post("/notify/welcome?email=user@example.com&name=John")
    assert res.status_code == 200

# ─── Get User Email (internal) ────────────────────────────────────────────────
@pytest.mark.anyio
async def test_get_user_email_success():
    from main import get_user_email
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value.status_code = 200
        mock_get.return_value.json.return_value = {"email": "user@example.com"}
        email = await get_user_email("user-123")
    assert email == "user@example.com"

@pytest.mark.anyio
async def test_get_user_email_not_found():
    from main import get_user_email
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value.status_code = 404
        email = await get_user_email("non-existent")
    assert email is None
