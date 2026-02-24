-- ═══════════════════════════════════════════════════════════════════════════
-- init-databases.sql
-- Run once to create all service databases and schemas
-- Used by docker-compose for local dev, and RDS init for production
-- ═══════════════════════════════════════════════════════════════════════════

-- Create databases
CREATE DATABASE usersdb;
CREATE DATABASE ordersdb;
CREATE DATABASE productsdb;
CREATE DATABASE analyticsdb;

-- ── Users DB Schema ───────────────────────────────────────────────────────────
\c usersdb;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS users (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name          VARCHAR(255)  NOT NULL,
  email         VARCHAR(255)  UNIQUE NOT NULL,
  password_hash VARCHAR(255)  NOT NULL,
  role          VARCHAR(50)   NOT NULL DEFAULT 'user',
  is_active     BOOLEAN       NOT NULL DEFAULT true,
  last_login    TIMESTAMP,
  created_at    TIMESTAMP     NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_email    ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_role     ON users(role);
CREATE INDEX IF NOT EXISTS idx_users_active   ON users(is_active);

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE PROCEDURE update_updated_at();

-- ── Orders DB Schema ──────────────────────────────────────────────────────────
\c ordersdb;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS orders (
  id               UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID           NOT NULL,
  items            JSONB          NOT NULL,
  total_amount     NUMERIC(12,2)  NOT NULL,
  status           VARCHAR(50)    NOT NULL DEFAULT 'pending',
  shipping_address TEXT           NOT NULL,
  payment_ref      VARCHAR(255),
  notes            TEXT,
  created_at       TIMESTAMP      NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMP      NOT NULL DEFAULT NOW(),
  CONSTRAINT valid_status CHECK (status IN (
    'pending','confirmed','processing','shipped','delivered','cancelled'
  ))
);

CREATE INDEX IF NOT EXISTS idx_orders_user_id  ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_status   ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_created  ON orders(created_at DESC);

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE PROCEDURE update_updated_at();

-- ── Products DB Schema ────────────────────────────────────────────────────────
\c productsdb;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS products (
  id             VARCHAR(36)    PRIMARY KEY,
  name           VARCHAR(255)   NOT NULL,
  description    TEXT,
  price          NUMERIC(12,2)  NOT NULL CHECK (price > 0),
  stock_quantity INTEGER        NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
  category       VARCHAR(100),
  sku            VARCHAR(100)   UNIQUE NOT NULL,
  image_url      VARCHAR(500),
  is_active      BOOLEAN        NOT NULL DEFAULT true,
  created_at     TIMESTAMP      NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMP      NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_products_category  ON products(category);
CREATE INDEX IF NOT EXISTS idx_products_sku        ON products(sku);
CREATE INDEX IF NOT EXISTS idx_products_active     ON products(is_active);
CREATE INDEX IF NOT EXISTS idx_products_price      ON products(price);

-- ── Analytics DB Schema ───────────────────────────────────────────────────────
\c analyticsdb;

CREATE TABLE IF NOT EXISTS analytics_events (
  id         VARCHAR(36)   PRIMARY KEY,
  event_type VARCHAR(100)  NOT NULL,
  user_id    VARCHAR(36),
  session_id VARCHAR(100),
  page       VARCHAR(255),
  properties JSONB,
  ip_address VARCHAR(50),
  user_agent TEXT,
  created_at TIMESTAMP     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_events_type       ON analytics_events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_user_id    ON analytics_events(user_id);
CREATE INDEX IF NOT EXISTS idx_events_session    ON analytics_events(session_id);
CREATE INDEX IF NOT EXISTS idx_events_created    ON analytics_events(created_at DESC);

CREATE TABLE IF NOT EXISTS metrics (
  id          VARCHAR(36)  PRIMARY KEY,
  metric_name VARCHAR(100) NOT NULL,
  value       FLOAT        NOT NULL,
  labels      JSONB,
  recorded_at TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_metrics_name       ON metrics(metric_name);
CREATE INDEX IF NOT EXISTS idx_metrics_recorded   ON metrics(recorded_at DESC);
