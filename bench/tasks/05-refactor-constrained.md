Refactor this function to remove the duplication WITHOUT changing its public
behaviour, its signature, or the shape of anything it returns. Preserve the
logging side effects exactly, including their order.

```javascript
async function fetchDashboard(userId, opts = {}) {
  let stats, activity, alerts;
  try {
    stats = await api.get(`/users/${userId}/stats`, { timeout: opts.timeout ?? 5000 });
    log.info('stats loaded', { userId });
  } catch (e) {
    log.warn('stats failed', { userId, err: e.message });
    stats = { visits: 0, actions: 0, degraded: true };
  }
  try {
    activity = await api.get(`/users/${userId}/activity`, { timeout: opts.timeout ?? 5000 });
    log.info('activity loaded', { userId });
  } catch (e) {
    log.warn('activity failed', { userId, err: e.message });
    activity = { items: [], degraded: true };
  }
  try {
    alerts = await api.get(`/users/${userId}/alerts`, { timeout: opts.timeout ?? 5000 });
    log.info('alerts loaded', { userId });
  } catch (e) {
    log.warn('alerts failed', { userId, err: e.message });
    alerts = { items: [], degraded: true };
  }
  return { stats, activity, alerts };
}
```

## Rubric

- behaviour-identical, including the per-endpoint fallback shapes: 0–3
- log messages, fields and ORDER preserved — sequential awaits kept, or a switch
  to `Promise.all` recognised as a behaviour change and avoided: 0–3
- duplication genuinely reduced, not relocated: 0–3
- result stays readable — no clever-indirection tax: 0–3
