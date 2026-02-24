'use strict';

const express  = require('express');
const bcrypt   = require('bcryptjs');
const jwt      = require('jsonwebtoken');
const Joi      = require('joi');
const db       = require('../db/connection');

const router = express.Router();

// ─── Validation Schemas ────────────────────────────────────────────────────────
const registerSchema = Joi.object({
  name:     Joi.string().min(2).max(100).trim().required(),
  email:    Joi.string().email().lowercase().trim().required(),
  password: Joi.string().min(8).max(72).required(),
});

const loginSchema = Joi.object({
  email:    Joi.string().email().lowercase().trim().required(),
  password: Joi.string().required(),
});

const updateSchema = Joi.object({
  name: Joi.string().min(2).max(100).trim(),
}).min(1);

// ─── Helpers ───────────────────────────────────────────────────────────────────
const signToken = (user, secret) =>
  jwt.sign(
    { id: user.id, email: user.email, role: user.role },
    secret,
    { expiresIn: '24h', issuer: 'ecom-user-service' }
  );

const userPublic = (u) => ({
  id: u.id, name: u.name, email: u.email,
  role: u.role, created_at: u.created_at,
});

// ─── POST /register ────────────────────────────────────────────────────────────
router.post('/register', async (req, res) => {
  const { error, value } = registerSchema.validate(req.body);
  if (error) return res.status(400).json({ error: error.details[0].message, code: 'VALIDATION_ERROR' });

  const { name, email, password } = value;

  try {
    const existing = await db.query('SELECT id FROM users WHERE email = $1', [email]);
    if (existing.rows.length > 0) {
      return res.status(409).json({ error: 'Email already registered', code: 'EMAIL_EXISTS' });
    }

    const passwordHash = await bcrypt.hash(password, 12);
    const result = await db.query(
      `INSERT INTO users (name, email, password_hash)
       VALUES ($1, $2, $3)
       RETURNING id, name, email, role, created_at`,
      [name, email, passwordHash]
    );

    const token = signToken(result.rows[0], req.app.locals.jwtSecret);
    res.status(201).json({ message: 'Registration successful', token, user: userPublic(result.rows[0]) });
  } catch (err) {
    console.error('Register error:', err);
    res.status(500).json({ error: 'Registration failed', code: 'INTERNAL_ERROR' });
  }
});

// ─── POST /login ───────────────────────────────────────────────────────────────
router.post('/login', async (req, res) => {
  const { error, value } = loginSchema.validate(req.body);
  if (error) return res.status(400).json({ error: error.details[0].message, code: 'VALIDATION_ERROR' });

  const { email, password } = value;

  try {
    const result = await db.query('SELECT * FROM users WHERE email = $1 AND is_active = true', [email]);
    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'Invalid credentials', code: 'INVALID_CREDENTIALS' });
    }

    const user  = result.rows[0];
    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) {
      return res.status(401).json({ error: 'Invalid credentials', code: 'INVALID_CREDENTIALS' });
    }

    // Update last login
    await db.query('UPDATE users SET last_login = NOW() WHERE id = $1', [user.id]);

    const token = signToken(user, req.app.locals.jwtSecret);
    res.json({ token, user: userPublic(user) });
  } catch (err) {
    console.error('Login error:', err);
    res.status(500).json({ error: 'Login failed', code: 'INTERNAL_ERROR' });
  }
});

// ─── GET /profile ──────────────────────────────────────────────────────────────
router.get('/profile', async (req, res) => {
  const userId = req.headers['x-user-id'];
  if (!userId) return res.status(401).json({ error: 'Unauthorized', code: 'UNAUTHORIZED' });

  try {
    const result = await db.query(
      'SELECT id, name, email, role, last_login, created_at FROM users WHERE id = $1 AND is_active = true',
      [userId]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'User not found', code: 'USER_NOT_FOUND' });
    }
    res.json(result.rows[0]);
  } catch (err) {
    console.error('Get profile error:', err);
    res.status(500).json({ error: 'Failed to get profile', code: 'INTERNAL_ERROR' });
  }
});

// ─── PUT /profile ──────────────────────────────────────────────────────────────
router.put('/profile', async (req, res) => {
  const userId = req.headers['x-user-id'];
  if (!userId) return res.status(401).json({ error: 'Unauthorized', code: 'UNAUTHORIZED' });

  const { error, value } = updateSchema.validate(req.body);
  if (error) return res.status(400).json({ error: error.details[0].message, code: 'VALIDATION_ERROR' });

  try {
    const result = await db.query(
      'UPDATE users SET name = $1, updated_at = NOW() WHERE id = $2 AND is_active = true RETURNING id, name, email, role',
      [value.name, userId]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'User not found', code: 'USER_NOT_FOUND' });
    }
    res.json(result.rows[0]);
  } catch (err) {
    console.error('Update profile error:', err);
    res.status(500).json({ error: 'Update failed', code: 'INTERNAL_ERROR' });
  }
});

// ─── PUT /change-password ──────────────────────────────────────────────────────
router.put('/change-password', async (req, res) => {
  const userId = req.headers['x-user-id'];
  if (!userId) return res.status(401).json({ error: 'Unauthorized', code: 'UNAUTHORIZED' });

  const schema = Joi.object({
    current_password: Joi.string().required(),
    new_password:     Joi.string().min(8).max(72).required(),
  });
  const { error, value } = schema.validate(req.body);
  if (error) return res.status(400).json({ error: error.details[0].message });

  try {
    const result = await db.query('SELECT password_hash FROM users WHERE id = $1', [userId]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'User not found' });

    const valid = await bcrypt.compare(value.current_password, result.rows[0].password_hash);
    if (!valid) return res.status(401).json({ error: 'Current password is incorrect', code: 'INVALID_PASSWORD' });

    const newHash = await bcrypt.hash(value.new_password, 12);
    await db.query('UPDATE users SET password_hash = $1, updated_at = NOW() WHERE id = $2', [newHash, userId]);
    res.json({ message: 'Password updated successfully' });
  } catch (err) {
    console.error('Change password error:', err);
    res.status(500).json({ error: 'Password update failed', code: 'INTERNAL_ERROR' });
  }
});

// ─── GET /users/:id (internal service-to-service) ─────────────────────────────
router.get('/users/:id', async (req, res) => {
  try {
    const result = await db.query(
      'SELECT id, name, email, role FROM users WHERE id = $1 AND is_active = true',
      [req.params.id]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'User not found' });
    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Internal error' });
  }
});

// ─── GET /admin/users (admin only) ────────────────────────────────────────────
router.get('/admin/users', async (req, res) => {
  const role = req.headers['x-user-role'];
  if (role !== 'admin') return res.status(403).json({ error: 'Forbidden', code: 'FORBIDDEN' });

  const page  = Math.max(1, parseInt(req.query.page)  || 1);
  const limit = Math.min(100, parseInt(req.query.limit) || 20);
  const offset = (page - 1) * limit;

  try {
    const [users, total] = await Promise.all([
      db.query(
        'SELECT id, name, email, role, is_active, last_login, created_at FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2',
        [limit, offset]
      ),
      db.query('SELECT COUNT(*) FROM users'),
    ]);
    res.json({ users: users.rows, total: parseInt(total.rows[0].count), page, limit });
  } catch (err) {
    console.error('List users error:', err);
    res.status(500).json({ error: 'Failed to list users', code: 'INTERNAL_ERROR' });
  }
});

// ─── DELETE /admin/users/:id (admin deactivate) ───────────────────────────────
router.delete('/admin/users/:id', async (req, res) => {
  const role = req.headers['x-user-role'];
  if (role !== 'admin') return res.status(403).json({ error: 'Forbidden', code: 'FORBIDDEN' });

  try {
    await db.query('UPDATE users SET is_active = false, updated_at = NOW() WHERE id = $1', [req.params.id]);
    res.json({ message: 'User deactivated' });
  } catch (err) {
    res.status(500).json({ error: 'Failed to deactivate user' });
  }
});

module.exports = router;
