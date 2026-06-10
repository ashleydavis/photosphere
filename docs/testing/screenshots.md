# Capturing Desktop App Screenshots

The desktop app can be driven headlessly to capture screenshots of its screens.
This is useful for UX reviews, documentation, and visual checks. It reuses the
same **test control server** that the smoke tests use, so no manual clicking is
required.

## Quick start

From the repo root:

```bash
bun run screenshots
```

This bundles the frontend and desktop app, launches the app headless (via
`xvfb-run` on Linux), opens the 50-asset fixture, walks through the main screens,
and writes PNGs to `ux-review/screenshots/` (gitignored).

To watch the app while it runs (Linux), set `SHOW_UI=1`:

```bash
SHOW_UI=1 bun run screenshots
```

To write the screenshots somewhere else, set `OUT_DIR`:

```bash
OUT_DIR=/tmp/shots bun run screenshots
```

## How it works

The script is `apps/desktop/screenshots/capture-ux.sh`. It sources the smoke-test
helpers in `apps/desktop/smoke-tests/lib/common.sh` and:

1. Starts the app in test mode (`PHOTOSPHERE_TEST_MODE=1`), which starts an HTTP
   **test control server** on a free port.
2. Waits for `GET /ready`.
3. Sends commands to the control server to open the fixture database, navigate
   between pages, click elements, and capture screenshots.
4. Quits the app and lists the captured files.

### The `/screenshot` endpoint

The control server (`apps/desktop/src/lib/test-control-server.ts`) exposes a
`POST /screenshot` endpoint. It calls Electron's
`webContents.capturePage()` and writes the PNG to the path you give it:

```bash
curl -s -X POST "http://localhost:$PORT/screenshot" \
  -H "Content-Type: application/json" \
  -d '{"outputPath":"/path/to/shot.png"}'
```

`capturePage()` renders correctly under `xvfb-run`, so screenshots work fully
headless without a physical display.

### Other useful control-server endpoints

These are the endpoints the capture script drives. All are `POST` with a JSON
body unless noted.

| Endpoint            | Body                                  | Effect                                              |
| ------------------- | ------------------------------------- | --------------------------------------------------- |
| `/ready` (GET)      | -                                     | `200` once the window has loaded                    |
| `/navigate`         | `{ "page": "gallery" }`               | Navigates to an in-app route                        |
| `/open-database`    | `{ "path": "/abs/path" }`             | Opens an existing database                          |
| `/click`            | `{ "dataId": "...", "nth": 0 }`       | Calls `.click()` on the matching `data-id` element  |
| `/long-press-click` | `{ "dataId": "...", "nth": 0 }`       | Dispatches a real mousedown+mouseup (short click)   |
| `/screenshot`       | `{ "outputPath": "/abs/file.png" }`   | Captures the window to a PNG                         |
| `/quit`             | -                                     | Quits the app                                       |

Notes:

- **Gallery thumbnails need `/long-press-click`, not `/click`.** The thumbnail
  uses long-press handlers, so a plain DOM `.click()` is ignored. Use
  `/long-press-click` to open the photo viewer.
- **Routes** available include `gallery`, `import`, `map`, `databases`,
  `secrets`, `news`, `about`, `database-summary`.
- Elements are targeted by their `data-id` attribute. Grep the frontend for
  `data-id="..."` to find clickable targets.

## Extending the capture

Add steps to `apps/desktop/screenshots/capture-ux.sh`. The script defines two
helpers:

- `shot <name> [settle_secs]` - waits, then screenshots to `OUT_DIR/<name>.png`.
- `nav_shot <route> <name> [settle_secs]` - navigates to a route, then `shot`.

Capture order matters for stateful panels: the right-hand search/sort panel opens
as a persistent overlay that its open button cannot dismiss, so it is captured
last to avoid overlapping other pages.
