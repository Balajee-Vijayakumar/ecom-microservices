'use strict';

const { Pool } = require('pg');
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');

const smClient = new SecretsManagerClient({ region: process.env.AWS_REGION || 'us-east-2' });
let pool;

const getDBSecret = async () => {
  if (process.env.NODE_ENV === 'local' || process.env.NODE_ENV === 'test') {
    return {
      host:     process.env.DB_HOST     || 'localhost',
      port:     process.env.DB_PORT     || 5432,
      dbname:   process.env.DB_NAME     || 'usersdb',
      username: process.env.DB_USER     || 'postgres',
      password: process.env.DB_PASSWORD || 'password',
    };
  }
  const PROJECT = process.env.PROJECT_NAME || 'ecom-microservices';
  const ENV     = process.env.ENVIRONMENT  || 'prod';
  const res = await smClient.send(new GetSecretValueCommand({
    SecretId: `${PROJECT}/${ENV}/rds/credentials`,
  }));
  return JSON.parse(res.SecretString);
};

const connect = async () => {
  const secret = await getDBSecret();
  pool = new Pool({
    host:     secret.host,
    port:     Number(secret.port) || 5432,
    database: secret.dbname,
    user:     secret.username,
    password: secret.password,
    max:      20,
    idleTimeoutMillis:    30000,
    connectionTimeoutMillis: 5000,
    ssl: process.env.NODE_ENV !== 'local' && process.env.NODE_ENV !== 'test'
      ? { rejectUnauthorized: false }
      : false,
  });

  // Test connection
  await pool.query('SELECT 1');
  console.log('Database connected');

  // Create tables
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      name         VARCHAR(255)        NOT NULL,
      email        VARCHAR(255) UNIQUE NOT NULL,
      password_hash VARCHAR(255)       NOT NULL,
      role         VARCHAR(50)         NOT NULL DEFAULT 'user',
      is_active    BOOLEAN             NOT NULL DEFAULT true,
      last_login   TIMESTAMP,
      created_at   TIMESTAMP           NOT NULL DEFAULT NOW(),
      updated_at   TIMESTAMP           NOT NULL DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
    CREATE INDEX IF NOT EXISTS idx_users_role  ON users(role);
  `);
  console.log('Database schema ready');
  return pool;
};

const getPool = () => {
  if (!pool) throw new Error('Database not initialized. Call connect() first.');
  return pool;
};

const query = (text, params) => getPool().query(text, params);

const disconnect = async () => {
  if (pool) await pool.end();
};

module.exports = { connect, getPool, query, disconnect };
