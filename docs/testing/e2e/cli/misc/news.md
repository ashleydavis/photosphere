# CLI Manual Test: News

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `news` shows the latest update notification and every news item, including ones already seen.

This needs an internet connection: the news comes from the Photosphere feed.

## Prep

Move into the CLI source directory and point the CLI at an empty config directory, so no news item counts as seen yet:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
```

Expected: no output.

## Test

### 1. Show the news

```bash
bun run start -- news
```

Expected:
- One or more news items are printed, and the command exits successfully.

---

### 2. Show the news again

```bash
bun run start -- news
```

Expected:
- The same items are printed again, although they have now been seen.

## Check

The news output in steps 1 and 2 is the check.
