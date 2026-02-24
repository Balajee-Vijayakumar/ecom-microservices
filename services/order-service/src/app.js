'use strict';

const express  = require('express');
const helmet   = require('helmet');
const morgan   = require('morgan');
const Joi      = require('joi');
const axios    = require('axios');
const amqp     = require('amqplib');
const { Pool } = require('pg');
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');

const app  = express();
const PORT = process.env.PORT || 3002;

app.use(helmet());
app.use(express.json({ limit: '512kb' }));
app.use(morgan('combined'));

// ─── State ────────────────────────────────────────────────────────────────────
let pool;
let amqpChannel;

// ─── Secrets ──────────────────────────────────────────────────────────────────
const smClient = new SecretsManagerClient({ region: process.env.AWS_REGION || 'us-east-2' });

const getSecret = async (name) => {
  const res = await smClient.send(new GetSecretValueCommand({ SecretId: name }));
  return JSON.parse(res.SecretString);
};

// ─── DB Setup ─────────────────────────────────────────────────────────────────
const initDB = async () => {
  const PROJECT = process.env.PROJECT_NAME || 'ecom-microservices';
  const ENV     = process.env.ENVIRONMENT  || 'prod';
  const isLocal = process.env.NODE_ENV === 'local' || process.env.NODE_ENV === 'test';

  const secret = isLocal
    ? { host: process.env.DB_HOST || 'localhost', port: 5432, dbname: process.env.DB_NAME || 'ordersdb', username: process.env.DB_USER || 'postgres', password: process.env.DB_PASSWORD || 'password' }
    : await getSecret(`${PROJECT}/${ENV}/rds/credentials`);

  pool = new Pool({
    host:     secret.host,
    port:     Number(secret.port) || 5432,
    database: secret.dbname,
    user:     secret.username,
    password: secret.password,
    max: 20,
    ssl: !isLocal ? { rejectUnauthorized: false } : false,
  });

  await pool.query(`
    CREATE TABLE IF NOT EXISTS orders (
      id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id          UUID        NOT NULL,
      items            JSONB       NOT NULL,
      total_amount     NUMERIC(12,2) NOT NULL,
      status           VARCHAR(50) NOT NULL DEFAULT 'pending',
      shipping_address TEXT        NOT NULL,
      payment_ref      VARCHAR(255),
      notes            TEXT,
      created_at       TIMESTAMP   NOT NULL DEFAULT NOW(),
      updated_at       TIMESTAMP   NOT NULL DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS idx_orders_user_id ON orders(user_id);
    CREATE INDEX IF NOT EXISTS idx_orders_status  ON orders(status);
    CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at DESC);
  `);
  console.log('Orders DB ready');
};

// ─── RabbitMQ Setup ───────────────────────────────────────────────────────────
const initRabbitMQ = async () => {
  const PROJECT = process.env.PROJECT_NAME || 'ecom-microservices';
  const ENV     = process.env.ENVIRONMENT  || 'prod';
  const isLocal = process.env.NODE_ENV === 'local' || process.env.NODE_ENV === 'test';

  const rabbitmqUrl = isLocal
    ? (process.env.RABBITMQ_URL || 'amqp://localhost:5672')
    : (await getSecret(`${PROJECT}/${ENV}/app/rabbitmq`)).url;

  const retryConnect = async (retries = 5) => {
    for (let i = 0; i < retries; i++) {
      try {
        const conn = await amqp.connect(rabbitmqUrl);
        amqpChannel = await conn.createChannel();
        await amqpChannel.assertExchange('order_events', 'topic', { durable: true });
        await amqpChannel.assertQueue('order_events', { durable: true });
        conn.on('error', () => setTimeout(initRabbitMQ, 5000));
        console.log('RabbitMQ connected');
        return;
      } catch (err) {
        console.warn(`RabbitMQ attempt ${i + 1}/${retries} failed: ${err.message}`);
        await new Promise((r) => setTimeout(r, 3000));
      }
    }
    console.warn('RabbitMQ unavailable — events will be skipped');
  };
  await retryConnect();
};

const publishEvent = (eventType, data) => {
  if (!amqpChannel) return;
  const msg = JSON.stringify({ eventType, data, timestamp: new Date().toISOString() });
  amqpChannel.sendToQueue('order_events', Buffer.from(msg), { persistent: true });
};

// ─── Validation ────────────────────────────────────────────────────────────────
const orderCreateSchema = Joi.object({
  items: Joi.array().items(Joi.object({
    product_id: Joi.string().uuid().required(),
    name:       Joi.string().required(),
    quantity:   Joi.number().integer().min(1).required(),
    price:      Joi.number().positive().required(),
  })).min(1).required(),
  shipping_address: Joi.string().min(10).required(),
  notes: Joi.string().max(500).optional(),
});

const VALID_STATUSES = ['pending','confirmed','processing','shipped','delivered','cancelled'];

// ─── Routes ────────────────────────────────────────────────────────────────────
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'healthy', service: 'order-service', db: 'connected', queue: amqpChannel ? 'connected' : 'unavailable' });
  } catch {
    res.status(503).json({ status: 'unhealthy' });
  }
});

// POST / — Create order
app.post('/', async (req, res) => {
  const userId = req.headers['x-user-id'];
  if (!userId) return res.status(401).json({ error: 'Unauthorized', code: 'UNAUTHORIZED' });

  const { error, value } = orderCreateSchema.validate(req.body);
  if (error) return res.status(400).json({ error: error.details[0].message, code: 'VALIDATION_ERROR' });

  const { items, shipping_address, notes } = value;

  // Validate each product exists via Product Service
  const productServiceUrl = process.env.PRODUCT_SERVICE_URL || 'http://product-service:8000';
  try {
    await Promise.all(
      items.map((item) =>
        axios.get(`${productServiceUrl}/products/${item.product_id}`, { timeout: 5000 })
          .catch(() => { throw new Error(`Product ${item.product_id} not found or unavailable`); })
      )
    );
  } catch (err) {
    return res.status(422).json({ error: err.message, code: 'PRODUCT_VALIDATION_FAILED' });
  }

  const totalAmount = items.reduce((sum, i) => sum + i.price * i.quantity, 0).toFixed(2);

  try {
    const result = await pool.query(
      `INSERT INTO orders (user_id, items, total_amount, shipping_address, notes)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [userId, JSON.stringify(items), totalAmount, shipping_address, notes || null]
    );
    const order = result.rows[0];
    publishEvent('ORDER_CREATED', { orderId: order.id, userId, totalAmount, items });
    res.status(201).json(order);
  } catch (err) {
    console.error('Create order error:', err);
    res.status(500).json({ error: 'Failed to create order', code: 'INTERNAL_ERROR' });
  }
});

// GET / — List user orders
app.get('/', async (req, res) => {
  const userId = req.headers['x-user-id'];
  if (!userId) return res.status(401).json({ error: 'Unauthorized', code: 'UNAUTHORIZED' });

  const page   = Math.max(1, parseInt(req.query.page)  || 1);
  const limit  = Math.min(50, parseInt(req.query.limit) || 10);
  const offset = (page - 1) * limit;
  const { status } = req.query;

  try {
    let q = 'SELECT * FROM orders WHERE user_id = $1';
    const params = [userId];
    if (status && VALID_STATUSES.includes(status)) {
      q += ` AND status = $${params.length + 1}`;
      params.push(status);
    }
    q += ` ORDER BY created_at DESC LIMIT $${params.length + 1} OFFSET $${params.length + 2}`;
    params.push(limit, offset);

    const [orders, countRes] = await Promise.all([
      pool.query(q, params),
      pool.query('SELECT COUNT(*) FROM orders WHERE user_id = $1', [userId]),
    ]);
    res.json({ orders: orders.rows, total: parseInt(countRes.rows[0].count), page, limit });
  } catch (err) {
    console.error('List orders error:', err);
    res.status(500).json({ error: 'Failed to fetch orders', code: 'INTERNAL_ERROR' });
  }
});

// GET /:id — Get single order
app.get('/:id', async (req, res) => {
  const userId = req.headers['x-user-id'];
  const role   = req.headers['x-user-role'];
  if (!userId) return res.status(401).json({ error: 'Unauthorized', code: 'UNAUTHORIZED' });

  try {
    const q = role === 'admin'
      ? 'SELECT * FROM orders WHERE id = $1'
      : 'SELECT * FROM orders WHERE id = $1 AND user_id = $2';
    const params = role === 'admin' ? [req.params.id] : [req.params.id, userId];
    const result = await pool.query(q, params);
    if (result.rows.length === 0) return res.status(404).json({ error: 'Order not found', code: 'ORDER_NOT_FOUND' });
    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch order', code: 'INTERNAL_ERROR' });
  }
});

// PATCH /:id/status — Update order status
app.patch('/:id/status', async (req, res) => {
  const role = req.headers['x-user-role'];
  if (role !== 'admin') return res.status(403).json({ error: 'Forbidden', code: 'FORBIDDEN' });

  const { status } = req.body;
  if (!VALID_STATUSES.includes(status)) {
    return res.status(400).json({ error: `Invalid status. Must be one of: ${VALID_STATUSES.join(', ')}`, code: 'INVALID_STATUS' });
  }

  try {
    const result = await pool.query(
      'UPDATE orders SET status = $1, updated_at = NOW() WHERE id = $2 RETURNING *',
      [status, req.params.id]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Order not found', code: 'ORDER_NOT_FOUND' });

    const order = result.rows[0];
    publishEvent('ORDER_STATUS_UPDATED', { orderId: order.id, userId: order.user_id, status });
    res.json(order);
  } catch (err) {
    res.status(500).json({ error: 'Failed to update status', code: 'INTERNAL_ERROR' });
  }
});

// GET /admin/all — Admin: list all orders
app.get('/admin/all', async (req, res) => {
  const role = req.headers['x-user-role'];
  if (role !== 'admin') return res.status(403).json({ error: 'Forbidden', code: 'FORBIDDEN' });

  const page   = Math.max(1, parseInt(req.query.page)  || 1);
  const limit  = Math.min(100, parseInt(req.query.limit) || 20);
  const offset = (page - 1) * limit;

  try {
    const result = await pool.query(
      'SELECT * FROM orders ORDER BY created_at DESC LIMIT $1 OFFSET $2',
      [limit, offset]
    );
    const total = await pool.query('SELECT COUNT(*) FROM orders');
    res.json({ orders: result.rows, total: parseInt(total.rows[0].count), page, limit });
  } catch (err) {
    res.status(500).json({ error: 'Failed to list orders', code: 'INTERNAL_ERROR' });
  }
});

app.use((err, req, res, _next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error', code: 'INTERNAL_ERROR' });
});

// ─── Bootstrap ────────────────────────────────────────────────────────────────
const start = async () => {
  try {
    await Promise.all([initDB(), initRabbitMQ()]);
    app.listen(PORT, () => console.log(`Order Service running on port ${PORT}`));
  } catch (err) {
    console.error('Startup failed:', err);
    process.exit(1);
  }
};

process.on('SIGTERM', async () => {
  if (amqpChannel) await amqpChannel.close().catch(() => {});
  if (pool) await pool.end();
  process.exit(0);
});

start();
module.exports = { app, pool: () => pool };
