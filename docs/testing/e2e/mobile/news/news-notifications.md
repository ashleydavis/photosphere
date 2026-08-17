# Mobile Manual Test: News Notifications

Test that news published for the app reaches the phone, is readable, and does not keep announcing itself once read.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

The desktop test uses a local feed through `PHOTOSPHERE_NEWS_URL` (see `docs/testing/e2e/desktop/news/setup-news-feed.sh`). On the phone, run against the published feed unless you can point the build at your own.

## Steps

### 1. See the news

1. Open the app with a network connection.

Expected: Unread news is indicated, rather than arriving silently.

---

### 2. Read it

1. Open the news.

Expected:
- The entries are readable and fit the phone screen, with no text cut off at the edges.
- Links open in the device browser rather than inside the app.

---

### 3. It stays read

1. Close the app completely and reopen it.

Expected: The news you read is not announced again.

---

### 4. No network

1. Put the phone in flight mode and open the app.

Expected: The app opens and works normally. Missing news is not an error worth blocking on, and must not stop the gallery loading.
