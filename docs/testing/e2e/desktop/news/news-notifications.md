# Desktop Manual Test: News Notifications

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that news notifications appear on first sight and can be dismissed, and
that dismissed items do not reappear on subsequent launches.

## Prep

This test points the app at a local news YAML file using the
`PHOTOSPHERE_NEWS_URL` environment variable, which must be set before the app
launches.

Open a terminal at the repo root for the desktop app. Every command below runs in that one terminal.

Clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-news-notifications
```

Run the setup script to write the local news feed, then point the app at it. From the repo root:

```bash
./docs/testing/e2e/desktop/news/setup-news-feed.sh
export PHOTOSPHERE_NEWS_URL="file:///tmp/photosphere-news.yaml"
```

Run this in the same terminal. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-news-notifications/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-news-notifications/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-news-notifications/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-news-notifications/logs
export XDG_DATA_HOME=/tmp/psi-desktop-news-notifications/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-news-notifications/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

Start the desktop app in the same terminal (so `PHOTOSPHERE_NEWS_URL` and the exports above are still set), from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`:

```bash
bun run linux
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. First startup shows the first news item

After the app launches:

Expected:
- A toast appears for `smoke-test-001` ("Welcome to Photosphere").
- The toast offers Read more / Try it actions (or equivalent links).
- The second item (`smoke-test-002`) is not shown.

---

### 2. Dismiss the first item

1. Click the dismiss button on the toast.

Expected:
- The toast disappears.
- The app records the dismissal (the news state file, `/tmp/psi-desktop-news-notifications/config/state.yaml`, now contains `smoke-test-001`).

## Check

### 3. Restart the app

Stop the app and start it again in the same terminal, so `PHOTOSPHERE_NEWS_URL` and the other exports from Prep are still set.

Expected:
- A toast appears for `smoke-test-002` (the second, never-seen item).
- The first item does not reappear.

---

### 4. Dismiss the second item and restart again

1. Dismiss the second toast.
2. Stop the app and start it again in the same terminal, so the exports still apply.

Expected:
- No news toasts appear (both items are now marked as shown).
