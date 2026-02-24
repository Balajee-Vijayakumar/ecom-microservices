import os, json, uuid, logging
from datetime import datetime
from typing import Optional, List
from contextlib import asynccontextmanager
from urllib.parse import quote_plus

import boto3
import databases
import sqlalchemy
from fastapi import FastAPI, HTTPException, Header, Query, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("product-service")

PROJECT  = os.getenv("PROJECT_NAME", "ecom-microservices")
ENV      = os.getenv("ENVIRONMENT",  "prod")
REGION   = os.getenv("AWS_REGION",   "us-east-2")
IS_LOCAL = os.getenv("APP_ENV", "production") in ("local", "test")

def get_db_url() -> str:
    if IS_LOCAL:
        host = os.getenv("DB_HOST", "localhost")
        user = os.getenv("DB_USER", "postgres")
        pwd  = os.getenv("DB_PASSWORD", "password")
        name = os.getenv("DB_NAME", "productsdb")
        return f"postgresql://{user}:{quote_plus(pwd)}@{host}:5432/{name}"
    sm = boto3.client("secretsmanager", region_name=REGION)
    secret = json.loads(sm.get_secret_value(SecretId=f"{PROJECT}/{ENV}/rds/credentials")["SecretString"])
    pwd = quote_plus(secret['password'])
    return f"postgresql://{secret['username']}:{pwd}@{secret['host']}:{secret.get('port',5432)}/{secret['dbname']}"

DATABASE_URL = get_db_url()
database     = databases.Database(DATABASE_URL)
metadata     = sqlalchemy.MetaData()

products = sqlalchemy.Table("products", metadata,
    sqlalchemy.Column("id",             sqlalchemy.String,        primary_key=True),
    sqlalchemy.Column("name",           sqlalchemy.String(255),   nullable=False),
    sqlalchemy.Column("description",    sqlalchemy.Text),
    sqlalchemy.Column("price",          sqlalchemy.Numeric(12,2), nullable=False),
    sqlalchemy.Column("stock_quantity", sqlalchemy.Integer,        default=0),
    sqlalchemy.Column("category",       sqlalchemy.String(100)),
    sqlalchemy.Column("sku",            sqlalchemy.String(100),   unique=True, nullable=False),
    sqlalchemy.Column("image_url",      sqlalchemy.String(500)),
    sqlalchemy.Column("is_active",      sqlalchemy.Boolean,        default=True),
    sqlalchemy.Column("created_at",     sqlalchemy.DateTime,       default=datetime.utcnow),
    sqlalchemy.Column("updated_at",     sqlalchemy.DateTime,       default=datetime.utcnow),
)

engine = sqlalchemy.create_engine(DATABASE_URL.replace("postgresql://", "postgresql+psycopg2://"))

class ProductCreate(BaseModel):
    name:           str   = Field(..., min_length=2, max_length=255)
    description:    Optional[str] = None
    price:          float = Field(..., gt=0)
    stock_quantity: int   = Field(0, ge=0)
    category:       Optional[str] = None
    sku:            str   = Field(..., min_length=2, max_length=100)
    image_url:      Optional[str] = None

class ProductUpdate(BaseModel):
    name:           Optional[str]   = None
    description:    Optional[str]   = None
    price:          Optional[float] = Field(None, gt=0)
    stock_quantity: Optional[int]   = Field(None, ge=0)
    category:       Optional[str]   = None
    image_url:      Optional[str]   = None
    is_active:      Optional[bool]  = None

class ProductOut(BaseModel):
    id:             str
    name:           str
    description:    Optional[str]
    price:          float
    stock_quantity: int
    category:       Optional[str]
    sku:            str
    image_url:      Optional[str]
    is_active:      bool
    created_at:     datetime
    updated_at:     datetime

@asynccontextmanager
async def lifespan(app: FastAPI):
    await database.connect()
    metadata.create_all(engine)
    logger.info("Product Service started")
    yield
    await database.disconnect()

app = FastAPI(title="Product Service", version="1.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

def require_admin(x_user_role: Optional[str] = Header(None)):
    if x_user_role != "admin":
        raise HTTPException(status_code=403, detail="Admin access required")

@app.get("/health")
async def health():
    try:
        await database.execute("SELECT 1")
        return {"status": "healthy", "service": "product-service"}
    except Exception:
        raise HTTPException(status_code=503, detail="DB unavailable")

@app.post("/products", response_model=ProductOut, status_code=201)
async def create_product(body: ProductCreate, _=Depends(require_admin)):
    pid = str(uuid.uuid4())
    now = datetime.utcnow()
    try:
        await database.execute(products.insert().values(id=pid, **body.dict(), is_active=True, created_at=now, updated_at=now))
    except Exception as e:
        if "unique" in str(e).lower():
            raise HTTPException(status_code=409, detail=f"SKU '{body.sku}' already exists")
        raise HTTPException(status_code=500, detail="Failed to create product")
    return await database.fetch_one(products.select().where(products.c.id == pid))

@app.get("/products", response_model=List[ProductOut])
async def list_products(page: int = Query(1, ge=1), limit: int = Query(20, ge=1, le=100),
    category: Optional[str] = None, search: Optional[str] = None,
    min_price: Optional[float] = None, max_price: Optional[float] = None):
    q = products.select().where(products.c.is_active == True)
    if category:  q = q.where(products.c.category == category)
    if search:    q = q.where(products.c.name.ilike(f"%{search}%"))
    if min_price: q = q.where(products.c.price >= min_price)
    if max_price: q = q.where(products.c.price <= max_price)
    q = q.order_by(products.c.created_at.desc()).limit(limit).offset((page - 1) * limit)
    return await database.fetch_all(q)

@app.get("/products/{product_id}", response_model=ProductOut)
async def get_product(product_id: str):
    row = await database.fetch_one(products.select().where(products.c.id == product_id))
    if not row:
        raise HTTPException(status_code=404, detail="Product not found")
    return row

@app.put("/products/{product_id}", response_model=ProductOut)
async def update_product(product_id: str, body: ProductUpdate, _=Depends(require_admin)):
    updates = {k: v for k, v in body.dict().items() if v is not None}
    if not updates:
        raise HTTPException(status_code=400, detail="No fields to update")
    updates["updated_at"] = datetime.utcnow()
    await database.execute(products.update().where(products.c.id == product_id).values(**updates))
    row = await database.fetch_one(products.select().where(products.c.id == product_id))
    if not row:
        raise HTTPException(status_code=404, detail="Product not found")
    return row

@app.patch("/products/{product_id}/stock")
async def update_stock(product_id: str, quantity_delta: int):
    row = await database.fetch_one(products.select().where(products.c.id == product_id))
    if not row:
        raise HTTPException(status_code=404, detail="Product not found")
    new_qty = row["stock_quantity"] + quantity_delta
    if new_qty < 0:
        raise HTTPException(status_code=400, detail=f"Insufficient stock. Available: {row['stock_quantity']}")
    await database.execute(products.update().where(products.c.id == product_id)
        .values(stock_quantity=new_qty, updated_at=datetime.utcnow()))
    return {"product_id": product_id, "stock_quantity": new_qty}

@app.delete("/products/{product_id}", status_code=204)
async def delete_product(product_id: str, _=Depends(require_admin)):
    await database.execute(products.update().where(products.c.id == product_id)
        .values(is_active=False, updated_at=datetime.utcnow()))

@app.get("/categories")
async def list_categories():
    rows = await database.fetch_all(
        sqlalchemy.select(products.c.category)
        .where(products.c.is_active == True)
        .where(products.c.category != None)
        .distinct()
    )
    return {"categories": [r["category"] for r in rows]}
