# CLI Manual Test: News

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `news` shows the latest update notification and every news item, including ones already seen.

This needs an internet connection: the news comes from the Photosphere feed.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at an empty config directory, so no news item counts as seen yet:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-news-news
mkdir -p /tmp/psi-cli-news-news/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-news-news/config
```

Expected: no output.

## Test

### 1. Show the news

```bash
psi news
```

Expected:
- One or more news items are printed, and the command exits successfully.

---

### 2. Show the news again

```bash
psi news
```

Expected:
- The same items are printed again, although they have now been seen.

## Check

The news output in steps 1 and 2 is the check.
