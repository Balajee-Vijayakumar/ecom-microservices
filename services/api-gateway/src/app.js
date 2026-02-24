'use strict';

const express  = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const rateLimit = require('express-rate-limit');
const helmet    = require('helmet');
const morgan    = require('morgan');
const cors      = require('cors');

const { loadConfig } = require('./config/secrets');
const { authenticate } = require('./middleware/auth');

const app  = express();
const PORT = process.env.PORT || 3000;

let config = {};

// ─── Security Middleware ───────────────────────────────────────────────────────
app.use(helmet());
app.use(cors({ origin: process.env.CORS_ORIGIN || '*', methods: ['GET','POST','PUT','PATCH','DELETE'] }));
app.use(express.json({ limit: '1mb' }));
app.use(morgan('combined'));

// ─── Rate Limiting ────────────────────────────────────────────────────────────
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 200,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests. Please try again later.', code: 'RATE_LIMIT_EXCEEDED' },
});

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  message: { error: 'Too many auth attempts. Please try again later.', code: 'AUTH_RATE_LIMIT' },
});

app.use('/api/', limiter);
app.use('/api/users/login',    authLimiter);
app.use('/api/users/register', authLimiter);

// ─── Health Check ─────────────────────────────────────────────────────────────
app.get('/health', (req, res) => {
  res.json({
    status:    'healthy',
    service:   'api-gateway',
    version:   process.env.APP_VERSION || '1.0.0',
    timestamp: new Date().toISOString(),
    uptime:    Math.floor(process.uptime()),
  });
});

// ─── Readiness Check ──────────────────────────────────────────────────────────
app.get('/ready', (req, res) => {
  if (!config.jwtSecret) {
    return res.status(503).json({ status: 'not ready', reason: 'config not loaded' });
  }
  res.json({ status: 'ready' });
});

// ─── Proxy factory ────────────────────────────────────────────────────────────
const makeProxy = (target, pathRewrite) =>
  createProxyMiddleware({
    target,
    changeOrigin: true,
    pathRewrite,
    timeout: 30000,
    on: {
      error: (err, req, res) => {
        console.error(`Proxy error to ${target}:`, err.message);
        res.status(502).json({ error: 'Upstream service unavailable', code: 'UPSTREAM_ERROR' });
      },
    },
  });

// ─── Routes (applied after config loads) ──────────────────────────────────────
const setupRoutes = () => {
  // Auth middleware
  app.use('/api/', authenticate(config));

  // ── User Service ──────────────────────────────────────────────────────────
  app.use('/api/users', makeProxy(config.userServiceUrl, { '^/api/users': '' }));

  // ── Order Service ─────────────────────────────────────────────────────────
  app.use('/api/orders', makeProxy(config.orderServiceUrl, { '^/api/orders': '' }));

  // ── Product Service ───────────────────────────────────────────────────────
  app.use('/api/products', makeProxy(config.productServiceUrl, { '^/api/products': '' }));

  // ── Analytics Service ─────────────────────────────────────────────────────
  app.use('/api/analytics', makeProxy(config.analyticsServiceUrl, { '^/api/analytics': '' }));

  // ── Notification Service (internal only) ──────────────────────────────────
  app.use('/api/notifications', makeProxy(config.notificationServiceUrl, { '^/api/notifications': '' }));

  // ── 404 ───────────────────────────────────────────────────────────────────
  app.use((req, res) => res.status(404).json({ error: 'Route not found', code: 'NOT_FOUND' }));

  // ── Global Error Handler ──────────────────────────────────────────────────
  app.use((err, req, res, _next) => {
    console.error('Unhandled error:', err);
    res.status(500).json({ error: 'Internal server error', code: 'INTERNAL_ERROR' });
  });
};

// ─── Bootstrap ────────────────────────────────────────────────────────────────
const start = async () => {
  try {
    console.log('Loading configuration from AWS Secrets Manager...');
    config = await loadConfig();
    console.log('Configuration loaded successfully');

    setupRoutes();

    app.listen(PORT, () => {
      console.log(`API Gateway running on port ${PORT} [${process.env.NODE_ENV || 'production'}]`);
    });
  } catch (err) {
    console.error('Failed to start API Gateway:', err);
    process.exit(1);
  }
};

// ─── Graceful Shutdown ────────────────────────────────────────────────────────
process.on('SIGTERM', () => {
  console.log('SIGTERM received — shutting down gracefully');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('SIGINT received — shutting down');
  process.exit(0);
});

start();
module.exports = app;
