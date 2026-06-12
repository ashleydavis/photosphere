# Video playback investigation (imported video shows a blank player)

Symptom: an imported video (e.g. `test.mp4`) opens the full-screen asset view but shows a
blank/black player. Photos display fine. Video does not.

Status: still NOT fixed. What is established:
- The `<video>` source is blocked (case A), confirmed by the DevTools probe below.
- The missing CSP `media-src` is *a* real cause of the CSP console error.
- BUT adding `media-src 'self' blob: http://localhost:*` and rebuilding did **not** make the video
  play. Tested 2026-06-12: result was *worse* — no blank player and no playback controls at all
  (the `<video>` appears not to render). So `media-src` alone is necessary-but-not-sufficient,
  exactly as the original note said. Adding it is not the fix.
- The probe error was `MEDIA_ELEMENT_ERROR: Media load rejected by URL safety check`. This points
  at Chromium refusing the `blob:file://` media URL itself (a media URL-safety restriction), which
  `media-src` does not address.

Earlier hypotheses (page origin via `app://`, Content-Type, GPU compositing) were tested and did
not fix it either. The only configuration that DOES play the video is `bun run dev:web`, where the
page origin is `http://localhost` and the media URL is `blob:http://localhost/…`.

## The core question to resolve first

"Blank video box" has two very different causes. Everything depends on which one it is:

- **(A) Not loading** — the `<video>` never gets valid media (CSP block, bad source, error).
  `video.error` is set, `readyState` is 0.
- **(B) Loading but not painting** — it decodes fine but does not draw on screen
  (GPU/compositing/layout). `video.error` is null, `readyState` is 4, but nothing is visible.

Until you know which, any "fix" is a guess.

## Do this first: the cleanest isolating test

- [x] Run `bun run dev:web` and open the app in a normal Chrome/Chromium tab (not Electron).
      Open the same imported video.
  - Plays in the browser → the problem is Electron-specific (file:// origin and/or GPU video
    compositing), not the app code. Focus on Electron.
  - Also blank in the browser → it is app code / CSP / source, reproducible in a normal
    debuggable browser with full DevTools. Much easier to chase there.
  - RESULT: Videos work ok in the browser.

## In the real app, get ground truth (DevTools) — DONE, proves case A

- [x] Open the video, press Ctrl+Shift+I, look at the Console for a red CSP error mentioning
      `media-src` / `blob`.
  - RESULT: yes. Console showed: `Loading media from 'blob:file:///…' violates the following
    Content Security Policy directive: "default-src 'self'". Note that 'media-src' was not
    explicitly set, so 'default-src' is used as a fallback. The action has been blocked.`
- [x] Run this in the console and note the output:

  ```js
  (() => { const v = document.querySelector('video'); return v ? { err: v.error && v.error.message, readyState: v.readyState, t: v.currentTime, w: v.videoWidth, h: v.videoHeight, ow: v.offsetWidth, oh: v.offsetHeight } : 'no video element'; })()
  ```

  - `err` set / `readyState` 0 (and `w`/`h` 0) → case A (loading).
  - `err` null, `readyState` 4, `w`/`h` = 1280/720, but `oh`/`ow` = 0 → the element has zero
    layout size (CSS/layout bug).
  - `err` null, `readyState` 4, sizes all non-zero, still blank on screen → case B (GPU
    compositing).
  - RESULT: `{ err: "MEDIA_ELEMENT_ERROR: Media load rejected by URL safety check", netState: 3,
    readyState: 0, t: 0, dur: null, w: 0, h: 0, ow: 2005, oh: 1335, src: "" }`.
    → **case A confirmed.** `err` set, `readyState` 0, `w/h` 0, `netState` 3 (NETWORK_NO_SOURCE),
    `currentSrc` empty. And `ow/oh` 2005×1335 → element is laid out, so **not** the layout case
    and **not** case B. The source is rejected by CSP before any decode.

## Specific questions

### `media-src` (Content Security Policy)

- CSP (the `<meta http-equiv="Content-Security-Policy">` in `apps/desktop-frontend/index.html`)
  whitelists where each resource type may load from. It has `img-src 'self' data: blob: ...`
  (so images load from blob URLs) but no `media-src`, so `<video>` falls back to
  `default-src 'self'` and the blob URL is blocked.
- TESTED 2026-06-12 under the normal `file://` build: added `media-src 'self' blob:
  http://localhost:*;`, rebuilt, reloaded. Video still did not play, and the player/controls
  disappeared entirely. So `media-src` is necessary to clear the CSP console error but is NOT the
  fix. The original "necessary-but-not-sufficient" caveat was correct.

### Old backend vs `asset-server`

- Old backend: git tag `Before-removing-the-backend`, file `packages/rest-api/src/lib/server.ts`,
  the `GET /asset` handler. It did `readStream.pipe(res)` — no Content-Type, no Range.
- Current: `packages/rest-api/src/lib/asset-server.ts` also pipes the whole stream but hardcodes
  `Content-Type: application/octet-stream`.
- Earlier theory (now DISPROVED): "the real difference is the page origin (`http://` web vs
  `file://` desktop)." The `app://` experiment above shows origin is not the cause.
- Also ruled out: Content-Type is **not** the differentiator. `bun run dev:web` (which works)
  serves assets through the *same* `createAssetServer` returning the *same*
  `Content-Type: application/octet-stream` (`apps/dev-server/src/index.ts` →
  `packages/rest-api/src/lib/asset-server.ts`). So the working web build plays an octet-stream
  blob fine; the desktop does not. The asset bytes themselves are fine (byte-identical, valid mp4).
- Worth doing regardless (but probably not the blank-video fix): make `asset-server` send the
  correct `Content-Type` (e.g. `video/mp4`) and support HTTP Range requests, so the player can
  stream/seek instead of the frontend downloading the whole file into a Blob. Diff `server.ts`
  vs `asset-server.ts` to see what got dropped.

### The `app://` custom protocol idea — TESTED, but the refutation is NOT clean

> UPDATE (2026-06-12, after reviewing external sources): treat the "origin is
> ruled out" conclusion below as **not reliable**. The `dev:web` build plays the
> video from a **blob** (`blob:http://localhost/…`), and the only material
> difference from the failing desktop build is the page scheme (`http://localhost`
> vs `file://`). That is positive evidence the `file://` origin is implicated. The
> `app://` test below does NOT cleanly refute it: it still fed the `<video>` a
> blob, and (per the section itself) captured no clean probe of `readyState` /
> `err` / `currentSrc` in that state, so we do not actually know whether the
> `app://` blob loaded-and-did-not-paint or was rejected. The clean one-variable
> test is Experiment 3 in "What to try next": load the page over `http://localhost`
> and keep the blob, reproducing the known-good `blob:http://localhost` condition.

- Properly retested (2026-06-12): registered `app://` as a **privileged standard + secure**
  scheme (`protocol.registerSchemesAsPrivileged` with `standard: true, secure: true,
  supportFetchAPI: true, stream: true, corsEnabled: true`), served the frontend bundle over it,
  loaded the page as `app://photosphere/index.html`, and added `media-src 'self' blob:
  http://localhost:*` to the CSP.
- RESULT: **still blank.** `app://photosphere` is a secure, standard origin — exactly the
  secure context that "blob media needs a secure origin" would require — yet the video did not
  appear. This was a clean test of the origin theory and it **failed**.
- Conclusion: the page origin (`file://` vs `app://` vs `http://`) is **not** the cause. The
  earlier "video played from `http://` but not `file://`/`app://`" minimal-test note is not a
  reliable basis to chase origin; do not pursue serving the frontend over `http://localhost` as
  a fix. The changes for this experiment were reverted.

## Other experiments (in priority order)

- [ ] Disable hardware acceleration to test case B: add `app.disableHardwareAcceleration()` near
      the top of `apps/desktop/src/main.ts` (before app ready), or launch with `--disable-gpu`.
      If the video appears → it is a GPU video-overlay/compositing problem (known Electron
      issue); chase GPU flags (`disable-gpu-compositing`, `disable-features=...`).
- [ ] Minimal Electron video test (rules out the machine/driver): a tiny standalone Electron app
      loading a plain HTML page with one `<video>` pointing at a local mp4. Renders → Electron/GPU
      can show video, so it is Photosphere-specific. Blank → it is the Electron build/driver/GPU,
      independent of Photosphere.
- [ ] Check the element's box in DevTools: select the `<video>` in the Elements panel and confirm
      it has non-zero width/height and is not covered by another element / `opacity:0` / behind a
      poster. The carousel uses absolute positioning + transforms
      (`packages/user-interface/src/components/carousel.tsx`), a plausible place for a zero-size
      or stacking bug.
- [ ] The `<video>` already has `controls`. If you see the scrubber/time bar but no picture →
      decoding/painting (case B). If you see nothing at all, not even controls → the element is
      not laid out or not there.
- [ ] Try a different video (a small, plain H.264 baseline mp4) to rule out anything
      file-specific (the tested bytes were fine).

## Honest caveat

Do not trust results from a headless run for the "is it visible" question. Headless can show a
frame in a screenshot that a real GPU will not paint on screen. Judge visibility only in the real
GUI (or the dev:web browser).

## What is known so far

- The served asset bytes are correct and a valid H.264/AAC mp4 (`ffprobe` confirmed; byte-identical
  to the original on disk).
- The `<video>` element's decode state reached `readyState 4` and `currentTime` advanced once CSP
  allowed the source — i.e. it was decoding/playing at the data level.
- Despite that, the player is blank on a real screen, which points at a load-vs-paint distinction
  not yet resolved (see "core question" above).
- Missing CSP `media-src` is a real, confirmed bug, but not a sufficient fix on its own.
- **Page origin is ruled out** (`app://` secure-origin test still blank — see that section).
- **Content-Type is ruled out** (`dev:web` works with the same `octet-stream` asset server).
- **Case B (GPU/compositing) is ruled out.** The DevTools ground-truth probe shows the source is
  rejected (`err` set, `readyState` 0, `w/h` 0, empty `currentSrc`) with the element fully laid
  out (`ow/oh` 2005×1335). Nothing decodes, so there is nothing to composite. The hardware-
  acceleration test was a dead end and was reverted.
- The earlier "readyState reached 4 / currentTime advanced" note came from a prior session where
  `media-src` was present in the CSP. In the current (reverted) build with no `media-src`, the
  blob is blocked outright (readyState 0). So that observation was about a *different* CSP state,
  not the current one.
- `media-src` is necessary to clear the CSP console error but does NOT fix playback (tested; made
  it worse). Root cause is NOT just the CSP.
- Best remaining lead: the media URL itself. Desktop builds a `blob:file://…` URL; the probe error
  `Media load rejected by URL safety check` indicates Chromium refuses that media URL. The working
  `dev:web` build differs only in that its media URL is `blob:http://localhost/…`. The `app://`
  test muddied this (no clean probe was captured), so it is not a reliable refutation.

## Findings from external sources (Electron local video, 2026-06-12)

Read five references on playing local video in Electron. Three were reachable
(dev.to, the BillelMessaadi GitHub player, the Electron `protocol` docs) plus the
key bug report; StackOverflow 77973516 and the Reddit thread are blocked to the
fetch tool, but every reachable source agrees on the same approach. None of them
use a `blob:` URL for the `<video>`. That is the headline: a `blob:` minted from a
`file://` page is the documented failure mode, and the consistent fix is to give
`<video>` a *streamable* URL it can issue Range requests against.

Important nuance (from the `dev:web` result): a blob is NOT inherently the
problem. The working web build feeds the player `blob:http://localhost/…` and it
plays. Chromium's media URL-safety check rejects a `blob:` URL specifically when
its origin is `file://`, not blobs in general. So the real variable is the scheme
the media URL resolves to (`http://localhost` / a privileged custom scheme = OK;
`file://` = rejected). Two independent ways to break the bad combination: stop
using a blob (Experiments 1 and 2 below), OR stop loading the page from `file://`
(Experiment 3 below). The `dev:web` evidence points AT the origin, so the "page
origin is ruled out" section below is overstated — see the note there.

The two patterns they use:

- **HTTP origin (what `dev:web` already does):** `<video src>` points at a normal
  `http://localhost:<port>/…` asset URL. The server must send `Content-Type:
  video/<x>`, `Accept-Ranges: bytes`, and honour `Range` requests so the player
  can stream and seek. This matches the only configuration we have seen play.
- **Privileged custom streaming scheme (the recommended desktop pattern):**
  register a scheme as privileged *before* `app.whenReady()` and serve it with
  `protocol.handle` + `net.fetch`:

  ```js
  // before app is ready
  protocol.registerSchemesAsPrivileged([{
      scheme: "media",
      privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, bypassCSP: true },
  }]);

  // after app is ready
  protocol.handle("media", (request) => {
      const localPath = resolveAssetPath(request.url);   // map media://asset/<id> -> file on disk
      return net.fetch(pathToFileURL(localPath).toString()); // preserves Content-Length + Range
  });
  ```

  Then `<video src="media://asset/<id>">` (no blob). `net.fetch` from a `file://`
  URL keeps `Content-Length` and Range support, so seeking works automatically.

Two gotchas they call out that we have not satisfied:

- **`stream: true` is mandatory for `<video>`/`<audio>` over a custom protocol.**
  Without it the media element buffers the whole response instead of streaming,
  and seeking breaks (`video.seekable.end()` returns 0). Electron bug
  [#38749](https://github.com/electron/electron/issues/38749) is exactly this:
  video served via `protocol.handle` is not seekable unless the scheme is
  registered with `stream: true`. `registerFileProtocol` is deprecated; use
  `protocol.handle`.
- **Do not pipe the whole file with a generic Content-Type.** Our
  `asset-server.ts` pipes the entire stream as `application/octet-stream` with no
  Range support. Even over `http://` that breaks streaming/seeking. `net.fetch`
  on a file URL handles Range for free; a hand-rolled HTTP server must implement
  `Range`/`206 Partial Content` itself.

Why this is *not* a repeat of the failed `app://` experiment above: that test
registered `app://` for the **frontend bundle** but still handed the `<video>` a
**blob** URL. The blob is the thing Chromium rejects ("Media load rejected by URL
safety check"). The fix here is to stop using a blob for video entirely and point
`src` at a streamable URL (http or a `stream: true` custom scheme), not to change
the page origin.

Sources:
- [Building a Secure Local Video Player in Electron (dev.to)](https://dev.to/bme/building-a-secure-local-video-player-in-electron-3ki9)
- [BillelMessaadi/electronjs-local-video-player (GitHub)](https://github.com/BillelMessaadi/electronjs-local-video-player)
- [Electron bug #38749: video files not seekable with protocol.handle](https://github.com/electron/electron/issues/38749)
- [Electron `protocol` API docs](https://www.electronjs.org/docs/latest/api/protocol)
- StackOverflow 77973516 and the r/electronjs thread (blocked to the fetch tool, but consistent with the above per the live web search).

## What to try next

- [ ] **Experiment 1 (smallest change) — bypass the blob, use the HTTP asset URL.** Set
      `<video src>` directly to the HTTP asset URL (`${restApiUrl}/asset?id=…&type=asset&db=…`)
      instead of `URL.createObjectURL(blob)`. The helper already exists: `assetUrl(assetId,
      assetType)` in `packages/user-interface/src/context/asset-database-source.tsx`. This gives
      the `<video>` an `http://localhost` media origin (exactly what works in `dev:web`) and
      avoids the `blob:file://` URL the safety check rejects. Edit
      `packages/user-interface/src/components/video.tsx` (only the video path needs this; images
      can keep blobs). Keep `media-src 'self' http://localhost:*` in the CSP so the http URL is
      allowed. **Also fix `asset-server.ts` to send `Content-Type: video/<x>`, `Accept-Ranges:
      bytes`, and honour `Range` requests** — without Range the player cannot stream/seek even
      over http (see external findings). UNTESTED.
- [ ] **Experiment 2 (recommended desktop pattern) — privileged custom streaming scheme.** If the
      http route is awkward, register a privileged scheme (e.g. `media://`) with
      `{ standard: true, secure: true, supportFetchAPI: true, stream: true, bypassCSP: true }`
      before `app.whenReady()` in `apps/desktop/src/main.ts`, serve it with
      `protocol.handle("media", req => net.fetch(pathToFileURL(localAssetPath).toString()))`, and
      set `<video src="media://asset/<id>">` (no blob). `net.fetch` preserves Content-Length and
      Range so seeking works for free. `stream: true` is REQUIRED (Electron bug #38749) or the
      element buffers instead of streaming and seeking breaks. This is genuinely different from the
      failed `app://` test, which still fed the video a blob. UNTESTED.
- [ ] **Experiment 3 (cleanest test of the origin theory) — keep the blob, change the page
      origin.** Load the Electron renderer over `http://localhost` (serve `bundle/frontend` from a
      small local http server instead of `mainWindow.loadURL("file://…")` in
      `apps/desktop/src/main.ts`) and change nothing else. The video src becomes
      `blob:http://localhost/…` — the exact condition that works in `dev:web`. If it plays, the
      `file://` origin is confirmed as the cause and the `app://` "ruled out" note is wrong. This
      is heavier than Experiments 1/2 (frontend must be served over http in production too), so
      prefer 1 or 2 as the actual fix; use this only to settle the origin question with one
      variable changed. UNTESTED.
- [ ] After any experiment, capture a clean probe in that state (`readyState`, `err`,
      `currentSrc`, and `video.seekable.end(0)`) before drawing any conclusion. Do not declare a
      fix without the video visibly playing AND seeking in the real GUI.
