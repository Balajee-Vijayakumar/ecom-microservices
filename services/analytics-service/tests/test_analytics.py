import pytest, os
os.environ["APP_ENV"]     = "test"
os.environ["DB_HOST"]     = "localhost"
os.environ["DB_NAME"]     = "analyticsdb"
os.environ["DB_USER"]     = "postgres"
os.environ["DB_PASSWORD"] = "testpassword"

from unittest.mock import AsyncMock, patch, MagicMock
from httpx import AsyncClient, ASGITransport
from main import app

@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c

# ─── Health ───────────────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_health_ok(client):
    with patch("main.database.execute", new_callable=AsyncMock, return_value=None):
        res = await client.get("/health")
    assert res.status_code == 200
    assert res.json()["status"] == "healthy"

@pytest.mark.anyio
async def test_health_db_down(client):
    with patch("main.database.execute", new_callable=AsyncMock, side_effect=Exception("DB down")):
        res = await client.get("/health")
    assert res.status_code == 503

# ─── Track Event ──────────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_track_event(client):
    with patch("main.database.execute", new_callable=AsyncMock, return_value=None):
        res = await client.post("/events", json={
            "event_type": "PAGE_VIEW",
            "session_id": "sess-123",
            "page": "/products",
            "properties": {"referrer": "google.com"}
        }, headers={"x-user-id": "user-abc"})
    assert res.status_code == 201
    assert "event_id" in res.json()
    assert res.json()["status"] == "tracked"

@pytest.mark.anyio
async def test_track_event_without_user(client):
    with patch("main.database.execute", new_callable=AsyncMock, return_value=None):
        res = await client.post("/events", json={"event_type": "ANONYMOUS_VIEW"})
    assert res.status_code == 201

# ─── Batch Track Events ───────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_track_events_batch(client):
    with patch("main.database.execute", new_callable=AsyncMock, return_value=None):
        res = await client.post("/events/batch", json=[
            {"event_type": "PAGE_VIEW", "page": "/home"},
            {"event_type": "BUTTON_CLICK", "properties": {"button": "buy_now"}},
        ], headers={"x-user-id": "user-abc"})
    assert res.status_code == 201
    assert res.json()["count"] == 2

# ─── Record Metric ────────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_record_metric(client):
    with patch("main.database.execute", new_callable=AsyncMock, return_value=None):
        res = await client.post("/metrics", json={
            "metric_name": "api_response_time_ms",
            "value": 145.5,
            "labels": {"service": "product-service", "endpoint": "/products"}
        })
    assert res.status_code == 201
    assert "metric_id" in res.json()

# ─── Dashboard ────────────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_dashboard_requires_admin(client):
    res = await client.get("/dashboard")
    assert res.status_code == 403

@pytest.mark.anyio
async def test_dashboard_as_admin(client):
    with patch("main.database.fetch_val", new_callable=AsyncMock, return_value=42), \
         patch("main.database.fetch_all", new_callable=AsyncMock, return_value=[]):
        res = await client.get("/dashboard?days=7", headers={"x-user-role": "admin"})
    assert res.status_code == 200
    data = res.json()
    assert data["period_days"] == 7
    assert data["total_events"] == 42
    assert "generated_at" in data

# ─── Sales Report ─────────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_sales_report_requires_admin(client):
    res = await client.get("/reports/sales")
    assert res.status_code == 403

@pytest.mark.anyio
async def test_sales_report_as_admin(client):
    with patch("main.database.fetch_all", new_callable=AsyncMock, return_value=[]):
        res = await client.get("/reports/sales?days=30", headers={"x-user-role": "admin"})
    assert res.status_code == 200
    assert res.json()["period_days"] == 30

# ─── User Journey ─────────────────────────────────────────────────────────────
@pytest.mark.anyio
async def test_user_journey_requires_admin(client):
    res = await client.get("/users/user-1/journey")
    assert res.status_code == 403

@pytest.mark.anyio
async def test_user_journey_as_admin(client):
    mock_events = [
        {"id": "e1", "event_type": "PAGE_VIEW", "user_id": "user-1", "created_at": "2024-01-01T00:00:00"}
    ]
    with patch("main.database.fetch_all", new_callable=AsyncMock, return_value=mock_events):
        res = await client.get("/users/user-1/journey", headers={"x-user-role": "admin"})
    assert res.status_code == 200
    assert res.json()["user_id"] == "user-1"
    assert res.json()["total"] == 1
