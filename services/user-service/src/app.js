'use strict';

const express = require('express');
const helmet  = require('helmet');
const morgan  = require('morgan');
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');

const db     = require('./db/connection');
const router = require('./routes/users');

const app  = express();
const PORT = process.env.PORT || 3001;

app.use(helmet());
app.use(express.json({ limit: '512kb' }));
app.use(morgan('combined'));

// ─── Health ────────────────────────────────────────────────────────────────────
app.get('/health', async (req, res) => {
  try {
    await db.query('SELECT 1');
    res.json({ status: 'healthy', service: 'user-service', db: 'connected' });
  } catch {
    res.status(503).json({ status: 'unhealthy', service: 'user-service', db: 'disconnected' });
  }
});

app.get('/ready', (req, res) => {
  try {
    db.getPool();
    res.json({ status: 'ready' });
  } catch {
    res.status(503).json({ status: 'not ready' });
  }
});

app.use('/', router);

app.use((err, req, res, _next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error', code: 'INTERNAL_ERROR' });
});

// ─── Load JWT secret ──────────────────────────────────────────────────────────
const loadJWTSecret = async () => {
  if (process.env.NODE_ENV === 'local' || process.env.NODE_ENV === 'test') {
    return process.env.JWT_SECRET || 'local-dev-secret';
  }
  const PROJECT = process.env.PROJECT_NAME || 'ecom-microservices';
  const ENV     = process.env.ENVIRONMENT  || 'prod';
  const client  = new SecretsManagerClient({ region: process.env.AWS_REGION || 'us-east-2' });
  const res = await client.send(new GetSecretValueCommand({
    SecretId: `${PROJECT}/${ENV}/app/jwt-secret`,
  }));
  return JSON.parse(res.SecretString).value;
};

// ─── Bootstrap ────────────────────────────────────────────────────────────────
const start = async () => {
  try {
    console.log('Connecting to database...');
    await db.connect();

    console.log('Loading JWT secret...');
    app.locals.jwtSecret = await loadJWTSecret();

    app.listen(PORT, () => {
      console.log(`User Service running on port ${PORT} [${process.env.NODE_ENV || 'production'}]`);
    });
  } catch (err) {
    console.error('Startup failed:', err);
    process.exit(1);
  }
};

process.on('SIGTERM', async () => {
  console.log('SIGTERM — disconnecting DB...');
  await db.disconnect();
  process.exit(0);
});

start();
module.exports = app;
