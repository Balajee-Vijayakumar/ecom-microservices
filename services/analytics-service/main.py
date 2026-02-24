import os, json, logging
from datetime import datetime
from typing import Optional
from contextlib import asynccontextmanager
from urllib.parse import quote_plus

import boto3
import databases
import sqlalchemy
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("analytics-service")

PROJECT  = os.getenv("PROJECT_NAME", "ecom-microservices")
ENV      = os.getenv("ENVIRONMENT",  "prod")
REGION   = os.getenv("AWS_REGION",   "us-east-2")
IS_LOCAL = os.getenv("APP_ENV", "production") in ("local", "test")

def get_db_url() -> str:
    if IS_LOCAL:
        host = os.getenv("DB_HOST", "localhost")
        user = os.getenv("DB_USER", "postgres")
        pwd  = os.getenv("DB_PASSWORD", "password")
        name = os.getenv("DB_NAME", "analyticsdb")
        return f"postgresql://{user}:{quote_plus(pwd)}@{host}:5432/{name}"
    sm = boto3.client("secretsmanager", region_name=REGION)
    secret = json.loads(sm.get_secret_value(SecretId=f"{PROJECT}/{ENV}/rds/credentials")["SecretString"])
    pwd = quote_plus(secret['password'])
    return f"postgresql://{secret['username']}:{pwd}@{secret['host']}:{secret.get('port',5432)}/{secret['dbname']}"

DATABASE_URL = get_db_url()
database     = databases.Database(DATABASE_URL)
metadata     = sqlalchemy.MetaData()

events = sqlalchemy.Table("analytics_events", metadata,
    sqlalchemy.Column("id",         sqlalchemy.String,  primary_key=True),
    sqlalchemy.Column("event_type", sqlalchemy.String(100)),
    sqlalchemy.Column("user_id",    sqlalchemy.String),
    sqlalchemy.Column("data",       sqlalchemy.Text),
    sqlalchemy.Column("created_at", sqlalchemy.DateTime, default=datetime.utcnow),
)

engine = sqlalchemy.create_engine(DATABASE_URL.replace("postgresql://", "postgresql+psycopg2://"))

@asynccontextmanager
async def lifespan(app: FastAPI):
    await database.connect()
    metadata.create_all(engine)
    logger.info("Analytics Service started")
    yield
    await database.disconnect()

app = FastAPI(title="Analytics Service", version="1.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

@app.get("/health")
async def health():
    try:
        await database.execute("SELECT 1")
        return {"status": "healthy", "service": "analytics-service"}
    except Exception:
        raise HTTPException(status_code=503, detail="DB unavailable")

@app.post("/events")
async def track_event(event: dict):
    import uuid
    await database.execute(events.insert().values(
        id=str(uuid.uuid4()),
        event_type=event.get("type", "unknown"),
        user_id=event.get("user_id"),
        data=json.dumps(event.get("data", {})),
        created_at=datetime.utcnow()
    ))
    return {"status": "tracked"}

@app.get("/summary")
async def summary():
    count = await database.fetch_val("SELECT COUNT(*) FROM analytics_events")
    return {"total_events": count, "service": "analytics-service"}
