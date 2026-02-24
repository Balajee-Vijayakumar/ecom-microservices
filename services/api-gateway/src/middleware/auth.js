'use strict';

const jwt = require('jsonwebtoken');

const PUBLIC_ROUTES = [
  { method: 'POST', path: '/api/users/register' },
  { method: 'POST', path: '/api/users/login' },
  { method: 'GET',  path: '/health' },
  { method: 'GET',  path: '/api/products' },
  { method: 'GET',  path: /^\/api\/products\/[^/]+$/ },
];

const isPublicRoute = (req) =>
  PUBLIC_ROUTES.some((r) => {
    const methodMatch = r.method === req.method;
    const pathMatch   = r.path instanceof RegExp
      ? r.path.test(req.path)
      : r.path === req.path;
    return methodMatch && pathMatch;
  });

const authenticate = (config) => (req, res, next) => {
  if (isPublicRoute(req)) return next();

  const authHeader = req.headers['authorization'];
  const token      = authHeader && authHeader.split(' ')[1];

  if (!token) {
    return res.status(401).json({ error: 'Access token required', code: 'TOKEN_MISSING' });
  }

  try {
    const decoded = jwt.verify(token, config.jwtSecret);
    req.user = decoded;
    // Forward user context to downstream services
    req.headers['x-user-id']    = decoded.id;
    req.headers['x-user-email'] = decoded.email;
    req.headers['x-user-role']  = decoded.role;
    next();
  } catch (err) {
    if (err.name === 'TokenExpiredError') {
      return res.status(401).json({ error: 'Token expired', code: 'TOKEN_EXPIRED' });
    }
    return res.status(403).json({ error: 'Invalid token', code: 'TOKEN_INVALID' });
  }
};

module.exports = { authenticate };
