import pytest, os
os.environ["APP_ENV"] = "test"
os.environ["DB_HOST"] = "localhost"
os.environ["DB_NAME"] = "testdb"
os.environ["DB_USER"] = "postgres"
os.environ["DB_PASSWORD"] = "testpassword"

from unittest.mock import AsyncMock, patch, MagicMock
from httpx import AsyncClient, ASGITransport
from main import app

@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c

@pytest.mark.anyio
async def test_health(client):
    with patch("main.database.execute", new_callable=AsyncMock, return_value=None):
        res = await client.get("/health")
    assert res.status_code == 200
    assert res.json()["status"] == "healthy"

@pytest.mark.anyio
async def test_list_products_empty(client):
    with patch("main.database.fetch_all", new_callable=AsyncMock, return_value=[]):
        res = await client.get("/products")
    assert res.status_code == 200
    assert res.json() == []

@pytest.mark.anyio
async def test_get_product_not_found(client):
    with patch("main.database.fetch_one", new_callable=AsyncMock, return_value=None):
        res = await client.get("/products/non-existent-id")
    assert res.status_code == 404

@pytest.mark.anyio
async def test_create_product_requires_admin(client):
    res = await client.post("/products", json={
        "name": "Test", "price": 9.99, "sku": "TEST-001", "stock_quantity": 10
    })
    assert res.status_code == 403

@pytest.mark.anyio
async def test_create_product_as_admin(client):
    mock_product = {
        "id": "uuid-1", "name": "Test Product", "description": None,
        "price": 9.99, "stock_quantity": 10, "category": None,
        "sku": "TEST-001", "image_url": None, "is_active": True,
        "created_at": "2024-01-01T00:00:00", "updated_at": "2024-01-01T00:00:00"
    }
    with patch("main.database.execute", new_callable=AsyncMock), \
         patch("main.database.fetch_one", new_callable=AsyncMock, return_value=mock_product):
        res = await client.post(
            "/products",
            json={"name": "Test Product", "price": 9.99, "sku": "TEST-001", "stock_quantity": 10},
            headers={"x-user-role": "admin"}
        )
    assert res.status_code == 201

@pytest.mark.anyio
async def test_update_stock_insufficient(client):
    mock_product = {"stock_quantity": 2}
    with patch("main.database.fetch_one", new_callable=AsyncMock, return_value=mock_product):
        res = await client.patch("/products/prod-1/stock?quantity_delta=-5")
    assert res.status_code == 400
    assert "Insufficient" in res.json()["detail"]
