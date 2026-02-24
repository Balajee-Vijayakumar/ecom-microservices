'use strict';

process.env.NODE_ENV  = 'local';
process.env.JWT_SECRET = 'test-secret-key-for-jest';

const request = require('supertest');
const jwt     = require('jsonwebtoken');

// Mock AWS SDK before requiring app
jest.mock('@aws-sdk/client-secrets-manager', () => ({
  SecretsManagerClient: jest.fn().mockImplementation(() => ({})),
  GetSecretValueCommand: jest.fn(),
}));
jest.mock('@aws-sdk/client-ssm', () => ({
  SSMClient: jest.fn().mockImplementation(() => ({})),
  GetParametersByPathCommand: jest.fn(),
}));
jest.mock('http-proxy-middleware', () => ({
  createProxyMiddleware: () => (req, res) => res.status(200).json({ proxied: true }),
}));

const app = require('../src/app');

const validToken = jwt.sign(
  { id: 'user-123', email: 'test@example.com', role: 'user' },
  'test-secret-key-for-jest',
  { expiresIn: '1h' }
);

describe('API Gateway', () => {
  describe('GET /health', () => {
    it('returns healthy status', async () => {
      const res = await request(app).get('/health');
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('healthy');
      expect(res.body.service).toBe('api-gateway');
    });
  });

  describe('Authentication middleware', () => {
    it('allows public route /api/users/login without token', async () => {
      const res = await request(app).post('/api/users/login').send({});
      expect(res.status).not.toBe(401);
    });

    it('allows public route /api/users/register without token', async () => {
      const res = await request(app).post('/api/users/register').send({});
      expect(res.status).not.toBe(401);
    });

    it('rejects protected route without token', async () => {
      const res = await request(app).get('/api/orders');
      expect(res.status).toBe(401);
      expect(res.body.code).toBe('TOKEN_MISSING');
    });

    it('rejects expired token', async () => {
      const expired = jwt.sign(
        { id: 'user-123', email: 'test@example.com', role: 'user' },
        'test-secret-key-for-jest',
        { expiresIn: '-1s' }
      );
      const res = await request(app)
        .get('/api/orders')
        .set('Authorization', `Bearer ${expired}`);
      expect(res.status).toBe(401);
      expect(res.body.code).toBe('TOKEN_EXPIRED');
    });

    it('rejects invalid token', async () => {
      const res = await request(app)
        .get('/api/orders')
        .set('Authorization', 'Bearer invalid.token.here');
      expect(res.status).toBe(403);
      expect(res.body.code).toBe('TOKEN_INVALID');
    });

    it('forwards user context headers with valid token', async () => {
      const res = await request(app)
        .get('/api/orders')
        .set('Authorization', `Bearer ${validToken}`);
      expect(res.status).toBe(200);
    });
  });

  describe('404 handler', () => {
    it('returns 404 for unknown routes', async () => {
      const res = await request(app)
        .get('/api/unknown-route')
        .set('Authorization', `Bearer ${validToken}`);
      expect(res.status).toBe(404);
      expect(res.body.code).toBe('NOT_FOUND');
    });
  });
});
