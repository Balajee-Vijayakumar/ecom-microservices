'use strict';

process.env.NODE_ENV   = 'test';
process.env.JWT_SECRET = 'test-secret';
process.env.DB_HOST    = 'localhost';
process.env.DB_NAME    = 'testdb';
process.env.DB_USER    = 'postgres';
process.env.DB_PASSWORD = 'testpassword';

jest.mock('@aws-sdk/client-secrets-manager', () => ({
  SecretsManagerClient: jest.fn(() => ({})),
  GetSecretValueCommand: jest.fn(),
}));

const request = require('supertest');
const bcrypt  = require('bcryptjs');

// Mock DB
const mockQuery = jest.fn();
jest.mock('../src/db/connection', () => ({
  connect:    jest.fn().mockResolvedValue(true),
  query:      mockQuery,
  getPool:    jest.fn().mockReturnValue({}),
  disconnect: jest.fn(),
}));

const app = require('../src/app');

beforeEach(() => {
  mockQuery.mockReset();
  app.locals.jwtSecret = 'test-secret';
});

describe('User Service', () => {
  describe('GET /health', () => {
    it('returns healthy when db is up', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [{ '?column?': 1 }] });
      const res = await request(app).get('/health');
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('healthy');
    });

    it('returns unhealthy when db is down', async () => {
      mockQuery.mockRejectedValueOnce(new Error('DB error'));
      const res = await request(app).get('/health');
      expect(res.status).toBe(503);
    });
  });

  describe('POST /register', () => {
    it('registers a new user successfully', async () => {
      mockQuery
        .mockResolvedValueOnce({ rows: [] }) // email check
        .mockResolvedValueOnce({ rows: [{ id: 'uuid-1', name: 'John', email: 'john@example.com', role: 'user', created_at: new Date() }] });

      const res = await request(app).post('/register').send({
        name: 'John Doe', email: 'john@example.com', password: 'password123',
      });
      expect(res.status).toBe(201);
      expect(res.body.token).toBeDefined();
      expect(res.body.user.email).toBe('john@example.com');
    });

    it('rejects duplicate email', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [{ id: 'existing' }] });
      const res = await request(app).post('/register').send({
        name: 'John', email: 'existing@example.com', password: 'password123',
      });
      expect(res.status).toBe(409);
      expect(res.body.code).toBe('EMAIL_EXISTS');
    });

    it('validates required fields', async () => {
      const res = await request(app).post('/register').send({ email: 'bad' });
      expect(res.status).toBe(400);
      expect(res.body.code).toBe('VALIDATION_ERROR');
    });
  });

  describe('POST /login', () => {
    it('logs in with valid credentials', async () => {
      const hash = await bcrypt.hash('password123', 12);
      mockQuery
        .mockResolvedValueOnce({ rows: [{ id: 'uuid-1', name: 'John', email: 'john@example.com', password_hash: hash, role: 'user', created_at: new Date() }] })
        .mockResolvedValueOnce({ rows: [] }); // update last_login

      const res = await request(app).post('/login').send({
        email: 'john@example.com', password: 'password123',
      });
      expect(res.status).toBe(200);
      expect(res.body.token).toBeDefined();
    });

    it('rejects wrong password', async () => {
      const hash = await bcrypt.hash('correctpass', 12);
      mockQuery.mockResolvedValueOnce({ rows: [{ id: 'uuid-1', email: 'j@e.com', password_hash: hash, role: 'user', is_active: true }] });

      const res = await request(app).post('/login').send({
        email: 'j@e.com', password: 'wrongpass',
      });
      expect(res.status).toBe(401);
      expect(res.body.code).toBe('INVALID_CREDENTIALS');
    });

    it('rejects non-existent user', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [] });
      const res = await request(app).post('/login').send({ email: 'nobody@x.com', password: 'pass' });
      expect(res.status).toBe(401);
    });
  });

  describe('GET /profile', () => {
    it('returns profile for authenticated user', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [{ id: 'uuid-1', name: 'John', email: 'j@e.com', role: 'user', created_at: new Date() }] });
      const res = await request(app).get('/profile').set('x-user-id', 'uuid-1');
      expect(res.status).toBe(200);
      expect(res.body.id).toBe('uuid-1');
    });

    it('returns 401 without user header', async () => {
      const res = await request(app).get('/profile');
      expect(res.status).toBe(401);
    });
  });
});
