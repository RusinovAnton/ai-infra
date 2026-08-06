Review this Express middleware module. Identify actual bugs (not style), rank
them by severity, and propose the minimal fix for the worst one.

```javascript
const jwt = require('jsonwebtoken');
const cache = new Map();

async function authMiddleware(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'missing token' });

  if (cache.has(token)) {
    req.user = cache.get(token);
    next();
  }

  try {
    const payload = jwt.verify(token, process.env.JWT_SECRET);
    if (payload.exp < Date.now()) {
      return res.status(401).json({ error: 'expired' });
    }
    const user = await db.users.findById(payload.sub);
    cache.set(token, user);
    req.user = user;
    next();
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
}

module.exports = authMiddleware;
```

## Rubric

- finds the missing `return` before the cached `next()` (double-response bug): 0–3
- finds `payload.exp` compared against milliseconds (JWT `exp` is seconds — and `jwt.verify` already enforces it): 0–3
- flags unbounded cache growth / stale user on permission change: 0–3
- flags 500-with-internals on verify failure (should be 401, no message leak): 0–3
- proposed fix is minimal and correct: 0–3
