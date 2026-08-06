Below is a request flow across four services. A user reports: "I updated my
email but password reset links still go to the old address." Trace the bug to
a specific line, explain the failure path end to end, and state the minimal
fix. There is exactly one bug.

```python
# ── service: accounts ────────────────────────────────────────────
class AccountService:
    def update_email(self, user_id, new_email):
        user = self.db.get_user(user_id)
        old_email = user.email
        user.email = new_email
        self.db.save(user)
        self.events.publish("email_changed", {
            "user_id": user_id, "old": old_email, "new": new_email,
        })
        self.audit.log(user_id, "email_changed")
        return user

# ── service: notifications (event consumer) ─────────────────────
class NotificationConsumer:
    def on_email_changed(self, event):
        # invalidate cached contact info so future sends use the new address
        self.contact_cache.delete(f"contact:{event['user_id']}")
        self.mailer.send(
            to=event["old"],
            template="email_change_notice",
            vars={"new_email": event["new"]},
        )

# ── service: auth (password reset) ──────────────────────────────
class PasswordResetService:
    def request_reset(self, login_email):
        user = self.db.find_by_email(login_email)
        if user is None:
            return  # do not reveal existence
        contact = self.contacts.get_contact(user.id)
        token = self.tokens.issue(user.id, ttl_minutes=30)
        self.mailer.send(
            to=contact.email,
            template="password_reset",
            vars={"link": f"https://app.example.com/reset?t={token}"},
        )

# ── service: contacts (shared client library) ───────────────────
class ContactsClient:
    def get_contact(self, user_id):
        key = f"user-contact:{user_id}"
        cached = self.cache.get(key)
        if cached is not None:
            return cached
        contact = self.api.fetch_contact(user_id)
        self.cache.set(key, contact, ttl=86400)
        return contact
```

## Rubric

- locates the bug precisely: the consumer deletes `contact:{id}` but the client
  caches under `user-contact:{id}` — the invalidation is a no-op: 0–3
- traces the full path (update → event → wrong-key delete → stale 24 h cache →
  reset mail to old address): 0–3
- minimal fix (align the key, ideally shared constant) rather than a cache
  redesign: 0–3
- does not get distracted into "bugs" that are deliberate design (sending the
  notice to the old address is correct security practice): 0–3
