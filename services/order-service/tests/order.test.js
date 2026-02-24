'use strict';

process.env.NODE_ENV    = 'test';
process.env.DB_HOST     = 'localhost';
process.env.DB_NAME     = 'ordersdb';
process.env.DB_USER     = 'postgres';
process.env.DB_PASSWORD = 'testpassword';
process.env.RABBITMQ_URL = 'amqp://localhost:5672';

// ── Mock AWS SDK ──────────────────────────────────────────────────────────────
jest.mock('@aws-sdk/client-secrets-manager', () => ({
  SecretsManagerClient: jest.fn(() => ({})),
  GetSecretValueCommand: jest.fn(),
}));

// ── Mock pg Pool ──────────────────────────────────────────────────────────────
const mockQuery = jest.fn();
jest.mock('pg', () => ({
  Pool: jest.fn().mockImplementation(() => ({
    query: mockQuery,
    end:   jest.fn().mockResolvedValue(true),
  })),
}));

// ── Mock amqplib ──────────────────────────────────────────────────────────────
jest.mock('amqplib', () => ({
  connect: jest.fn().mockResolvedValue({
    createChannel: jest.fn().mockResolvedValue({
      assertExchange: jest.fn().mockResolvedValue(true),
      assertQueue:    jest.fn().mockResolvedValue(true),
      sendToQueue:    jest.fn(),
      on:             jest.fn(),
    }),
    on: jest.fn(),
  }),
}));

// ── Mock axios ────────────────────────────────────────────────────────────────
jest.mock('axios', () => ({
  get: jest.fn().mockResolvedValue({ data: { id: 'prod-uuid', name: 'Test Product', price: 29.99 } }),
}));

const request = require('supertest');
const { app } = require('../src/app');

const VALID_ITEMS = [{
  product_id: '550e8400-e29b-41d4-a716-446655440000',
  name: 'Test Product',
  quantity: 2,
  price: 29.99,
}];

beforeEach(() => {
  mockQuery.mockReset();
  // Default: DB health check passes
  mockQuery.mockResolvedValue({ rows: [{ '?column?': 1 }] });
});

describe('Order Service', () => {

  describe('GET /health', () => {
    it('returns healthy status', async () => {
      const res = await request(app).get('/health');
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('healthy');
      expect(res.body.service).toBe('order-service');
    });

    it('returns unhealthy when DB is down', async () => {
      mockQuery.mockRejectedValueOnce(new Error('DB down'));
      const res = await request(app).get('/health');
      expect(res.status).toBe(503);
    });
  });

  describe('POST / — Create Order', () => {
    it('returns 401 without user header', async () => {
      const res = await request(app).post('/').send({ items: VALID_ITEMS, shipping_address: '123 Main St, City, State 12345' });
      expect(res.status).toBe(401);
      expect(res.body.code).toBe('UNAUTHORIZED');
    });

    it('creates order successfully', async () => {
      const order = {
        id: 'order-uuid-1', user_id: 'user-uuid-1', items: VALID_ITEMS,
        total_amount: '59.98', status: 'pending',
        shipping_address: '123 Main St, City, State 12345',
        created_at: new Date(), updated_at: new Date(),
      };
      mockQuery.mockResolvedValueOnce({ rows: [order] });

      const res = await request(app)
        .post('/')
        .set('x-user-id', 'user-uuid-1')
        .send({ items: VALID_ITEMS, shipping_address: '123 Main St, City, State 12345' });

      expect(res.status).toBe(201);
      expect(res.body.id).toBe('order-uuid-1');
      expect(res.body.status).toBe('pending');
    });

    it('validates missing items', async () => {
      const res = await request(app)
        .post('/')
        .set('x-user-id', 'user-uuid-1')
        .send({ shipping_address: '123 Main St' });
      expect(res.status).toBe(400);
      expect(res.body.code).toBe('VALIDATION_ERROR');
    });

    it('validates empty items array', async () => {
      const res = await request(app)
        .post('/')
        .set('x-user-id', 'user-uuid-1')
        .send({ items: [], shipping_address: '123 Main St, City, State 12345' });
      expect(res.status).toBe(400);
    });

    it('validates missing shipping address', async () => {
      const res = await request(app)
        .post('/')
        .set('x-user-id', 'user-uuid-1')
        .send({ items: VALID_ITEMS });
      expect(res.status).toBe(400);
    });
  });

  describe('GET / — List Orders', () => {
    it('returns 401 without user header', async () => {
      const res = await request(app).get('/');
      expect(res.status).toBe(401);
    });

    it('returns paginated orders for user', async () => {
      const orders = [
        { id: 'o1', user_id: 'user-1', status: 'pending', total_amount: '29.99', created_at: new Date() },
        { id: 'o2', user_id: 'user-1', status: 'shipped', total_amount: '59.99', created_at: new Date() },
      ];
      mockQuery
        .mockResolvedValueOnce({ rows: orders })
        .mockResolvedValueOnce({ rows: [{ count: '2' }] });

      const res = await request(app).get('/').set('x-user-id', 'user-1');
      expect(res.status).toBe(200);
      expect(res.body.orders).toHaveLength(2);
      expect(res.body.total).toBe(2);
      expect(res.body.page).toBe(1);
    });

    it('filters by status', async () => {
      mockQuery
        .mockResolvedValueOnce({ rows: [{ id: 'o1', status: 'shipped' }] })
        .mockResolvedValueOnce({ rows: [{ count: '1' }] });

      const res = await request(app).get('/?status=shipped').set('x-user-id', 'user-1');
      expect(res.status).toBe(200);
    });
  });

  describe('GET /:id — Get Single Order', () => {
    it('returns order for owner', async () => {
      mockQuery.mockResolvedValueOnce({
        rows: [{ id: 'order-1', user_id: 'user-1', status: 'pending' }],
      });
      const res = await request(app).get('/order-1').set('x-user-id', 'user-1');
      expect(res.status).toBe(200);
      expect(res.body.id).toBe('order-1');
    });

    it('returns 404 for non-existent order', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [] });
      const res = await request(app).get('/non-existent').set('x-user-id', 'user-1');
      expect(res.status).toBe(404);
      expect(res.body.code).toBe('ORDER_NOT_FOUND');
    });
  });

  describe('PATCH /:id/status — Update Status', () => {
    it('returns 403 for non-admin', async () => {
      const res = await request(app)
        .patch('/order-1/status')
        .set('x-user-id', 'user-1')
        .set('x-user-role', 'user')
        .send({ status: 'shipped' });
      expect(res.status).toBe(403);
    });

    it('updates status as admin', async () => {
      mockQuery.mockResolvedValueOnce({
        rows: [{ id: 'order-1', user_id: 'user-1', status: 'shipped' }],
      });
      const res = await request(app)
        .patch('/order-1/status')
        .set('x-user-id', 'admin-1')
        .set('x-user-role', 'admin')
        .send({ status: 'shipped' });
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('shipped');
    });

    it('rejects invalid status', async () => {
      const res = await request(app)
        .patch('/order-1/status')
        .set('x-user-role', 'admin')
        .send({ status: 'flying' });
      expect(res.status).toBe(400);
      expect(res.body.code).toBe('INVALID_STATUS');
    });
  });
});
