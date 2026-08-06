Write pytest tests for this function. Target the behaviour boundaries, not
coverage theatre — the interesting cases are at and around the limits.

```python
def paginate(items, page=1, per_page=20, max_per_page=100):
    """Return (page_items, total_pages). Raises ValueError on bad input."""
    if page < 1 or per_page < 1:
        raise ValueError("page and per_page must be >= 1")
    per_page = min(per_page, max_per_page)
    total_pages = max(1, -(-len(items) // per_page))
    if page > total_pages:
        return [], total_pages
    start = (page - 1) * per_page
    return items[start:start + per_page], total_pages
```

## Rubric

- boundary cases: empty list, exactly one page, `page == total_pages`, page beyond: 0–3
- `per_page` clamping to `max_per_page` tested: 0–3
- error cases via `pytest.raises`: 0–3
- no redundant tests padding the count: 0–3
