# News and Update Notifications

Photosphere shows two kinds of out-of-band notifications:

1. **Update available**: when a newer GitHub release exists than the running build.
2. **News**: short editorial messages (releases, blog posts, surveys) published in `news.yaml` at the repo root.

Both surface in the desktop UI and in every CLI command. Web and mobile are out of scope.

In the CLI, both checks run as a commander `preAction` hook in [`apps/cli/index.ts`](../apps/cli/index.ts), so every `psi <command>` prints the update line and the oldest unseen news item before doing its own work. The hook is skipped for two commands:

- `psi news`: renders its own full-feed listing (see below).
- `psi bug`: captures clean output for the bug report.

## Update notifications

A single async function `checkForUpdates()` lives in two places (no shared dependency between the CLI and the React frontend):

| Caller         | File                                                       |
|----------------|------------------------------------------------------------|
| Desktop / web  | [`packages/user-interface/src/lib/check-for-updates.ts`](../packages/user-interface/src/lib/check-for-updates.ts) |
| CLI            | [`apps/cli/src/lib/check-for-updates.ts`](../apps/cli/src/lib/check-for-updates.ts) |

Behaviour:

- Returns `undefined` when `version === 'dev'` or contains `'nightly'`.
- Otherwise fetches `https://api.github.com/repos/ashleydavis/photosphere/releases/latest` and compares its `tag_name` (stripped of a leading `v`) to the build version.
- Returns the latest version string when it differs from the running version; `undefined` otherwise.
- Any network or parse error is swallowed and returns `undefined`, so the check never blocks startup.

UI: the desktop main process (`apps/desktop/src/main.ts` → `checkForUpdate()`) runs the check on `did-finish-load`. When a newer version is available *and* the version is not already recorded in `news.yaml`'s `last_shown_update_version`, it sends an `update-available` IPC to the renderer. `navbar.tsx` subscribes via `platform.onUpdateAvailable()` and (a) renders a small pill in the top bar linking to the GitHub releases page as a persistent reminder, and (b) fires a one-off **primary-coloured toast** (`color: 'primary'`) with a "Download" action button. The toast is sticky (duration `0`) so the user has to dismiss it. After sending the IPC the main process records the version so it does not announce the same version again. In the CLI, the `preAction` hook prints a "📦 A new version is available" line before every command runs (and `psi news` prints it as the first line of its output); both then call `markUpdateAsShown()` to record the version in `news.yaml`. Subsequent runs do not re-announce the same version. Only a newer GitHub release re-triggers the notification.

The toast color union is `'primary' | 'success' | 'warning' | 'danger' | 'neutral'`. Update notifications use `'primary'`; news items pick their own color per-item via the publisher's `news.yaml` (defaulting to `'primary'` when none is specified) so a release can be `success`, a maintenance window can be `warning`, etc.

Update notifications are persisted via `last_shown_update_version` in `news.yaml`. The CLI silences repeat notifications for the same version, and the desktop main process suppresses sending the `update-available` IPC when the version has already been recorded.

## News notifications

The news feed is a YAML file with the following shape:

```yaml
items:
  - id: welcome-2026-05-05               # stable per-item key; must be unique forever
    message: "Welcome to Photosphere!"
    color: success                       # primary (default) | success | warning | danger | neutral
    duration: 0                          # ms; 0 = never auto-dismiss
    link:                                # optional inline anchor below the body
      label: "Read the docs"
      url: "https://github.com/ashleydavis/photosphere/wiki"
    action:                              # optional CTA button (URL form)
      label: "What's new"
      url: "https://github.com/ashleydavis/photosphere/releases/latest"
```

- Items are **ordered oldest-first**. New items are appended to the end.
- Only **one item is shown per startup**: the oldest one whose `id` is not in the shown set. This avoids overwhelming users after long absences.
- Shown IDs are persisted in `~/.config/photosphere/news.yaml` under `shown_news_ids` and are shared between the desktop app and the CLI on the same machine. The same file also stores `last_shown_update_version` for update notifications. Path is overridable via `PHOTOSPHERE_CONFIG_DIR`.

### Pipeline

1. `fetchNews(url)` in [`packages/api/src/lib/news-fetcher.ts`](../packages/api/src/lib/news-fetcher.ts) reads the YAML. Supports `http(s)://` URLs via global `fetch` and `file://` URLs via `fs/promises.readFile` (used by the smoke test).
2. `getShownNewsIds()` / `addShownNewsIds()` (plus `getLastShownUpdateVersion()` / `setLastShownUpdateVersion()` for the update side) in [`packages/api/src/lib/news-state.ts`](../packages/api/src/lib/news-state.ts) track which items and which update version have been shown. State lives in `news.yaml` next to `desktop.toml`.
3. Desktop: `checkForNews()` in [`apps/desktop/src/main.ts`](../apps/desktop/src/main.ts) fires from the `did-finish-load` event, picks the oldest unseen item, and sends it to the renderer as a `show-notification` IPC. The renderer adds it to the toast queue.
4. CLI: `checkForNews()` in [`apps/cli/src/lib/check-for-news.ts`](../apps/cli/src/lib/check-for-news.ts) is called from `printNotifications()` in [`apps/cli/src/lib/print-notifications.ts`](../apps/cli/src/lib/print-notifications.ts), which the commander `preAction` hook in [`apps/cli/index.ts`](../apps/cli/index.ts) invokes before every command. The oldest unseen item is printed inline and its id is recorded immediately, so subsequent CLI runs (and the desktop app) won't surface it again.
5. CLI (full listing): `psi news` calls `getAllNews()` and `markNewsAsShown()` (also in [`check-for-news.ts`](../apps/cli/src/lib/check-for-news.ts)) to render every item in the feed (seen or unseen) newest-first, with `(new)` markers on unseen items. After rendering, every unseen id is recorded so the regular `preAction` hook won't repeat them.

### Configuration

| Environment variable    | Effect                                                                                       |
|-------------------------|----------------------------------------------------------------------------------------------|
| `PHOTOSPHERE_NEWS_URL`  | Overrides the default GitHub URL. Accepts `http://`, `https://`, and `file://`. Used by smoke test 17 and for local development. |

Default URL: `https://raw.githubusercontent.com/ashleydavis/photosphere/main/news.yaml`.

In test mode (`PHOTOSPHERE_TEST_MODE=1`), the desktop news check is skipped unless `PHOTOSPHERE_NEWS_URL` is explicitly set, so unrelated smoke tests don't make network calls. The CLI does not currently honour `PHOTOSPHERE_TEST_MODE`; network failures in `checkForUpdates` / `checkForNews` are swallowed silently, so commands still succeed when offline.

### Failure mode

Network errors, malformed YAML, and missing item fields are all logged via `log.exception` (desktop) or swallowed silently (CLI). The user is never blocked by news failures.

### Publishing a new item

1. Append a new entry to the `items` list at the bottom of `news.yaml` in the repo root.
2. Pick a fresh `id`. Once seen on a user's machine, that ID is recorded forever.
3. Push to `main`. The file is served from `raw.githubusercontent.com/.../main/news.yaml`.

### `psi news` command

`psi news` always prints:

- The current update notification (or "You are running the latest version." when on the latest release).
- Every item from the news feed, newest-first, with `(new)` markers on items the user hasn't seen yet.

Running `psi news` marks every previously-unseen item as shown, so the regular `preAction` hook on other commands won't repeat them on the next invocation.
