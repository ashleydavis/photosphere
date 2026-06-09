# Desktop Manual Test: News Notifications

Test that news notifications appear on first sight and can be dismissed, and
that dismissed items do not reappear on subsequent launches.

## Prerequisites

This test points the app at a local news YAML file using the
`PHOTOSPHERE_NEWS_URL` environment variable, which must be set before the app
launches.

## Steps

### 1. Set up a local news feed

Run the setup script to write the local news feed. From the repo root:

```bash
./docs/testing/e2e/desktop/news/setup-news-feed.sh
export PHOTOSPHERE_NEWS_URL="file:///tmp/photosphere-news.yaml"
```

### 2. Start the desktop app

In the same terminal as step 1 (so `PHOTOSPHERE_NEWS_URL` is still set), from the
repo root:

```bash
bun run dev
```

---

### 3. First startup shows the first news item

After the app launches:

Expected:
- A toast appears for `smoke-test-001` ("Welcome to Photosphere").
- The toast offers Read more / Try it actions (or equivalent links).
- The second item (`smoke-test-002`) is not shown.

---

### 4. Dismiss the first item

1. Click the dismiss button on the toast.

Expected:
- The toast disappears.
- The app records the dismissal (the news state file now contains `smoke-test-001`).

---

### 5. Restart the app

Stop the app, ensure `PHOTOSPHERE_NEWS_URL` is still set, and re-start it.

Expected:
- A toast appears for `smoke-test-002` (the second, never-seen item).
- The first item does not reappear.

---

### 6. Dismiss the second item and restart again

1. Dismiss the second toast.
2. Stop and re-start the app.

Expected:
- No news toasts appear (both items are now marked as shown).
