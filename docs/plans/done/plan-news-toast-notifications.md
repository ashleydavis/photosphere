# News Toast Notifications from GitHub

## Overview
Photosphere Desktop should fetch a `news.yaml` file published in the GitHub repo at startup, detect items the local install has not yet seen, and display the **oldest unseen item** as a single toast notification. Each item supports an optional inline link (for "more detail") and an optional CTA action button — both opening external URLs in the system browser. Shown notification IDs are persisted in `desktop.toml` so each notification appears only once per install. Showing one item per startup avoids overwhelming the user when several items have been published since they last opened the app. This will be used to share Photosphere news (releases, blog posts, surveys, etc.) with users without bundling release-coupled changes.

## Issues
<!-- Populated later by plan:check -->

## Steps

### 1. Add `js-yaml` dependency to the `api` package
- Edit [packages/api/package.json](packages/api/package.json):
  - Add `"js-yaml": "^4.1.0"` to `dependencies`.
  - Add `"@types/js-yaml": "^4.0.9"` to `devDependencies`.
- Run `bun install` from the repo root to update the lockfile.

### 2. Create the news fetcher module
Create [packages/api/src/lib/news-fetcher.ts](packages/api/src/lib/news-fetcher.ts) with:

- Interfaces (each interface and field has a `//` comment block per project style):
  - `INewsLink { label: string; url: string; }` — a labelled URL.
  - `INewsItem { id: string; message: string; color?: 'success' | 'warning' | 'danger' | 'neutral'; duration?: number; link?: INewsLink; action?: INewsLink; }` — one news item.
  - `INewsFeed { items: INewsItem[]; }` — the parsed shape of `news.yaml`.
- Function `export async function fetchNews(url: string): Promise<INewsItem[]>` that:
  - For `file://` URLs, reads from disk via `fs/promises.readFile` (used only by smoke tests).
  - For `http://` / `https://` URLs, uses Node's global `fetch`. Throws if response is not OK.
  - Parses the body with `yaml.load` from `js-yaml`.
  - Validates the result is an object with an `items` array; throws `Error("Invalid news feed: missing items array")` otherwise.
  - Validates each item has a non-empty string `id` and `message`; throws on the first invalid item.
  - Returns the array of `INewsItem`.

### 3. Persist shown notification IDs in desktop config
Edit [packages/api/src/lib/desktop-config.ts](packages/api/src/lib/desktop-config.ts):

- Add `shownNotificationIds?: string[]` (with `//` comment) to `IDesktopConfig` (after `lastDatabase`).
- Add `shown_notification_ids?: string[]` to `ITomlDesktopConfig`.
- In `tomlToDesktopConfig`, copy `toml.shown_notification_ids → config.shownNotificationIds` when defined.
- In `desktopConfigToToml`, copy `config.shownNotificationIds → toml.shown_notification_ids` when defined.
- Add named exported function `getShownNotificationIds(): Promise<string[]>` that returns `(await loadDesktopConfig()).shownNotificationIds || []`.
- Add named exported function `addShownNotificationIds(ids: string[]): Promise<void>` that loads the config, dedupes the union of existing + new ids preserving order, sets `config.shownNotificationIds`, and saves.

### 4. Re-export the news fetcher from the api package
Edit [packages/api/src/index.ts](packages/api/src/index.ts) to add:
```ts
export * from "./lib/news-fetcher";
```
(`desktop-config` is already re-exported.)

### 5. Extend the show-notification IPC payload type
Edit [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx):

- Add a new exported interface above `IShowNotificationData`:
  ```ts
  // A labelled URL used for toast links and CTA actions.
  export interface IShowNotificationLink {
      // Visible label.
      label: string;
      // External URL opened when the link or action is clicked.
      url: string;
  }
  ```
- Add two new optional fields to `IShowNotificationData` (with `//` comment blocks):
  - `link?: IShowNotificationLink;` — inline link rendered in the toast body.
  - `action?: IShowNotificationLink;` — CTA action button (URL form). Mutually exclusive with the existing `folderPath` field; if both are present `action` wins.

### 6. Extend the toast model to support a link
Edit [packages/user-interface/src/context/toast-context.tsx](packages/user-interface/src/context/toast-context.tsx):

- Add an exported interface (with `//` doc):
  ```ts
  export interface IToastLink {
      label: string;
      url: string;
  }
  ```
- Add `link?: IToastLink;` to `IToast` (with comment).
- The `IAddToastInput` derived type already inherits `link` because it uses `Omit<IToast, 'id' | 'duration'>`. Confirm no further change is needed.

### 7. Render the inline link in the toast UI
Edit [packages/user-interface/src/components/toast-container.tsx](packages/user-interface/src/components/toast-container.tsx):

- In `ToastItem`, replace the bare `{toast.message}` body with a small wrapper that renders the message and, when `toast.link` is set, an anchor below it:
  ```tsx
  <div>
      <div>{toast.message}</div>
      {toast.link && (
          <a
              href={toast.link.url}
              target="_blank"
              rel="noopener noreferrer"
              style={{ display: 'inline-block', marginTop: 4, color: 'inherit', textDecoration: 'underline' }}
          >
              {toast.link.label}
          </a>
      )}
  </div>
  ```
- Do not change anything else in the file; preserve the existing `endDecorator` action button and dismiss button.

### 8. Wire show-notification handler to support url-based action and link
Edit [packages/user-interface/src/main.tsx](packages/user-interface/src/main.tsx) — the `useEffect` that subscribes to `platform.onShowNotification` (around line 120):

- Replace the body so the toast input includes:
  - `link: data.link` (passes through directly).
  - `action`: chosen in this priority order:
    1. If `data.action` is set → `{ label: data.action.label, onClick: () => window.open(data.action!.url, '_blank', 'noopener') }`.
    2. Else if `data.folderPath` is set → existing `{ label: 'Open Folder', onClick: () => platform.openFolder(data.folderPath!) }`.
    3. Else → `undefined`.
- The `window.open` call relies on the existing `setWindowOpenHandler` in [apps/desktop/src/main.ts](apps/desktop/src/main.ts) which routes externals through `shell.openExternal`. No change needed there.

### 9. Hook the news check into desktop main process startup
Edit [apps/desktop/src/main.ts](apps/desktop/src/main.ts):

- Add to the existing `import` from `'api'` the new symbols: `fetchNews`, `getShownNotificationIds`, `addShownNotificationIds`.
- Add a top-level constant:
  ```ts
  // URL of the news feed published in the Photosphere GitHub repo.
  const NEWS_URL = 'https://raw.githubusercontent.com/ashleydavis/photosphere/main/news.yaml';
  ```
- Add a new top-level `async function checkForNews(): Promise<void>` (with `//` doc block) that:
  1. Returns early if `mainWindow === null`.
  2. Reads `process.env.PHOTOSPHERE_NEWS_URL || NEWS_URL`.
  3. Wraps the work in a try/catch — on error, calls `log.exception('Failed to fetch news', error as Error)` and returns. (Project rule: avoid try/catch unless needed; here the requirement is to silently survive offline / GitHub outages, so the catch is justified — note this in the comment block.)
  4. Calls `await fetchNews(url)`. The returned `items` array is treated as ordered oldest-first (the publishing convention for `news.yaml`).
  5. Calls `await getShownNotificationIds()` and constructs a `Set<string>`.
  6. Iterates `items` in order and selects the **first** one whose `id` is not in the set → `nextItem` (single item, not an array).
  7. Returns early if `nextItem === undefined`.
  8. Calls `mainWindow.webContents.send('show-notification', { message: nextItem.message, color: nextItem.color || 'neutral', duration: nextItem.duration ?? 0, link: nextItem.link, action: nextItem.action })`.
  9. Calls `await addShownNotificationIds([nextItem.id])`.
  10. Calls `log.info(\`Showed news notification: ${nextItem.id}\`)`.
- Inside `createMainWindow()`, add to the existing `did-finish-load` handler (after the `testControlServer.notifyReady()` call):
  ```ts
  void checkForNews();
  ```
  (Fire-and-forget; the renderer is ready to receive `show-notification` IPCs at this point because the `onShowNotification` `useEffect` runs on the first render.)

### 10. Seed `news.yaml` at the repo root
Create [news.yaml](news.yaml) at the repo root with one initial test item, ordered oldest-first:

```yaml
items:
  - id: welcome-2026-05-05
    message: "Welcome to Photosphere — thanks for trying it out!"
    color: success
    link:
      label: "Read the docs"
      url: "https://github.com/ashleydavis/photosphere/wiki"
    action:
      label: "What's new"
      url: "https://github.com/ashleydavis/photosphere/releases/latest"
```

This file is the production feed served via `https://raw.githubusercontent.com/ashleydavis/photosphere/main/news.yaml`. New items are appended to the end of the `items` list so older readers see items in publication order.

## Unit Tests

### New: [packages/api/src/test/lib/news-fetcher.test.ts](packages/api/src/test/lib/news-fetcher.test.ts)
Use Jest. Mock global `fetch` via `jest.spyOn(globalThis, 'fetch')` (or `(globalThis as any).fetch = jest.fn()`).

Tests (using `test(`, not `it(`):
- `fetchNews returns parsed items when the YAML is valid`
- `fetchNews throws when the YAML is malformed`
- `fetchNews throws when items is missing`
- `fetchNews throws when an item is missing id`
- `fetchNews throws when an item is missing message`
- `fetchNews returns an empty array when items is empty`
- `fetchNews throws when the HTTP response is not ok`
- `fetchNews reads from disk for file:// URLs` (write a temp yaml file via `node-utils.writeFile` or `fs/promises`, then read it back)

### Update: [packages/api/src/test/lib/desktop-config.test.ts](packages/api/src/test/lib/desktop-config.test.ts)
Add to the existing test file:
- `loadDesktopConfig converts shown_notification_ids snake_case to camelCase`
- `saveDesktopConfig writes shown_notification_ids in TOML form`
- `getShownNotificationIds returns [] when unset`
- `getShownNotificationIds returns the stored list`
- `addShownNotificationIds appends new ids`
- `addShownNotificationIds dedupes existing ids`

## Smoke Tests

### New: [apps/desktop/smoke-tests/17-news-notifications/test.sh](apps/desktop/smoke-tests/17-news-notifications/test.sh)
Concrete shell script (modelled on `16-remove-recent-database/test.sh`). The script asserts the **one-item-per-startup** behaviour explicitly: across three startups it should show item-001, then item-002, then nothing.

1. `source` `lib/common.sh`, set `TMP_DIR`, `APP_PORT`.
2. Write a `news.yaml` to `$TMP_DIR/news.yaml` with two items, oldest-first. Example contents:
   ```yaml
   items:
     - id: smoke-test-001
       message: "Welcome to Photosphere"
       color: success
       link:
         label: "Read more"
         url: "https://example.com/read"
       action:
         label: "Try it"
         url: "https://example.com/try"
     - id: smoke-test-002
       message: "Second item"
   ```
3. Export `PHOTOSPHERE_NEWS_URL="file://$TMP_DIR/news.yaml"` and pass it through to `start_app`. Update `lib/common.sh::start_app` so that it forwards `PHOTOSPHERE_NEWS_URL` from the calling shell (add it to the env line in `start_app`).
4. **First startup:**
   - `start_app`, `wait_for_ready`.
   - `wait_for_log "$TMP_DIR" "Showed news notification: smoke-test-001"`.
   - Assert the log does **not** contain `"smoke-test-002"`: `grep -q 'smoke-test-002' "$TMP_DIR/app.log" && fail`.
   - Read `$TMP_DIR/config/desktop.toml` and assert `shown_notification_ids` contains exactly `smoke-test-001` (and not `smoke-test-002`).
   - `stop_app`.
5. **Second startup** (same `TMP_DIR` and `news.yaml`, app.log preserved by the harness — capture the log line count before starting so we can scope grep to the new run, e.g. `BASELINE=$(wc -l < "$TMP_DIR/app.log")`):
   - `start_app`, `wait_for_ready`.
   - `wait_for_log "$TMP_DIR" "Showed news notification: smoke-test-002"`.
   - Assert that no new `smoke-test-001` line appeared since `$BASELINE` (slice with `tail -n +$((BASELINE+1)) "$TMP_DIR/app.log" | grep -q smoke-test-001 && fail`).
   - Re-read `desktop.toml` and assert `shown_notification_ids` now contains both ids.
   - `stop_app`.
6. **Third startup** (everything seen — should show nothing):
   - Capture `BASELINE=$(wc -l < "$TMP_DIR/app.log")`.
   - `start_app`, `wait_for_ready`.
   - `sleep 3` to give the news fetch time to run.
   - Assert no `Showed news notification:` line appeared since `$BASELINE`.
   - `stop_app`.
7. `check_no_errors "$TMP_DIR"`.

If verifying the toast in the DOM is desired, add `data-id="toast-message-0"` (etc.) to the toast item in [toast-container.tsx](packages/user-interface/src/components/toast-container.tsx) and use `send_command "$APP_PORT" /get-value '{"dataId":"toast-message-0"}'`. The log-based assertions above are sufficient for the smoke test on their own.

## Verify
The AI agent must run all of the following from the repo root and confirm each passes:
- `bun run compile` — TypeScript compiles cleanly across the workspace.
- `bun run test` — all unit tests pass (covers `news-fetcher.test.ts` and the additions to `desktop-config.test.ts`).
- `bun run test:electron` — smoke tests pass, including the new test 17.

## Human Verification
A human can verify the feature works end-to-end:
1. Run `bun run dev` and confirm the app starts normally with no errors.
2. Create a temporary `news.yaml` on the local disk with **two** items (oldest first) — each with a `link` and an `action`. Set `PHOTOSPHERE_NEWS_URL=file:///path/to/news.yaml` in the environment.
3. Restart the app. Confirm **only the first (oldest) item** appears as a toast.
4. Click the inline link — it should open in the system browser.
5. Click the CTA action button — it should also open in the system browser.
6. Click the dismiss (×) button to remove the toast.
7. Restart the app. Confirm the **second item** now appears (and the first does not).
8. Restart the app a third time. Confirm no toast appears.
9. Add a third item to `news.yaml`. Restart. Confirm the third item appears.
10. (Optional) Inspect `~/.config/photosphere/desktop.toml` and confirm `shown_notification_ids` contains all three ids.

## Notes
- **One item per startup.** Even when multiple unseen items are pending, only the oldest unseen one is shown each time the app starts. This avoids drowning users in toasts after long absences and gives each item attention. Items are ordered oldest-first in `news.yaml` and consumed in that order across successive startups.
- **Single CTA button only.** The existing toast UI shows one action button via `endDecorator`. The user asked for a link AND a CTA — we satisfy this by rendering the link as inline anchor text in the body and keeping the action as the button. Both open external URLs.
- **Why a separate `INewsLink`/`IShowNotificationLink`/`IToastLink` rather than reusing `IToastAction`?** `IToastAction` carries a closure (`onClick`) which is not serialisable across the IPC boundary. The IPC payload uses URL form; the renderer converts it to a closure when constructing the toast.
- **Persistence growth.** Shown IDs accumulate forever in `desktop.toml`. At expected volumes (a handful of items per year) this is fine; not worth garbage collecting.
- **Failure mode.** Network errors, malformed YAML, and missing fields are all logged via `log.exception` and ignored. The user is never blocked by news fetch failures.
- **Web/mobile.** The fetch is wired only into `apps/desktop/src/main.ts`. Web and mobile platforms are out of scope for this plan.
- **Why fetch, not axios?** Node 18+ ships global `fetch`. Avoiding the axios dependency in the desktop main process keeps the bundle smaller. `axios` is already a dependency of `api`, but we do not need it here.
- **`file://` URL support** is included specifically so the smoke test can exercise the full pipeline without spinning up an HTTP server. Production traffic always uses HTTPS.
- **News file location on GitHub.** The constant `NEWS_URL` points at `https://raw.githubusercontent.com/ashleydavis/photosphere/main/news.yaml`. The user will publish and update this file separately; the plan does not commit it.
