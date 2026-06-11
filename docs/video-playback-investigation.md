# Video playback investigation (imported video shows a blank player)

Symptom: an imported video (e.g. `test.mp4`) opens the full-screen asset view but shows a
blank/black player. Photos display fine. Video does not.

This document is a troubleshooting checklist. Nothing here is a confirmed fix. One real bug was
found (missing CSP `media-src`) but fixing it alone did **not** make the video visible, so there
is at least one more cause behind it.

## The core question to resolve first

"Blank video box" has two very different causes. Everything depends on which one it is:

- **(A) Not loading** — the `<video>` never gets valid media (CSP block, bad source, error).
  `video.error` is set, `readyState` is 0.
- **(B) Loading but not painting** — it decodes fine but does not draw on screen
  (GPU/compositing/layout). `video.error` is null, `readyState` is 4, but nothing is visible.

Until you know which, any "fix" is a guess.

## Do this first: the cleanest isolating test

- [ ] Run `bun run dev:web` and open the app in a normal Chrome/Chromium tab (not Electron).
      Open the same imported video.
  - Plays in the browser → the problem is Electron-specific (file:// origin and/or GPU video
    compositing), not the app code. Focus on Electron.
  - Also blank in the browser → it is app code / CSP / source, reproducible in a normal
    debuggable browser with full DevTools. Much easier to chase there.

## In the real app, get ground truth (DevTools)

- [ ] Open the video, press Ctrl+Shift+I, look at the Console for a red CSP error mentioning
      `media-src` / `blob`.
- [ ] Run this in the console and note the output:

  ```js
  (() => { const v = document.querySelector('video'); return v ? { err: v.error && v.error.message, readyState: v.readyState, t: v.currentTime, w: v.videoWidth, h: v.videoHeight, ow: v.offsetWidth, oh: v.offsetHeight } : 'no video element'; })()
  ```

  - `err` set / `readyState` 0 (and `w`/`h` 0) → case A (loading).
  - `err` null, `readyState` 4, `w`/`h` = 1280/720, but `oh`/`ow` = 0 → the element has zero
    layout size (CSS/layout bug).
  - `err` null, `readyState` 4, sizes all non-zero, still blank on screen → case B (GPU
    compositing).

## Specific questions

### `media-src` (Content Security Policy)

- CSP (the `<meta http-equiv="Content-Security-Policy">` in `apps/desktop-frontend/index.html`)
  whitelists where each resource type may load from. It has `img-src 'self' data: blob: ...`
  (so images load from blob URLs) but no `media-src`, so `<video>` falls back to
  `default-src 'self'` and the blob URL is blocked.
- To apply: add `media-src 'self' data: blob: http://localhost:*;` to that CSP string, then
  rebuild (`bun run dev` re-bundles).
- Caveat: Chromium's own CSP violation report confirmed this block, so the directive is
  genuinely necessary, but adding it alone did NOT make the video visible. Treat it as
  necessary-but-not-sufficient.

### Old backend vs `asset-server`

- Old backend: git tag `Before-removing-the-backend`, file `packages/rest-api/src/lib/server.ts`,
  the `GET /asset` handler. It did `readStream.pipe(res)` — no Content-Type, no Range.
- Current: `packages/rest-api/src/lib/asset-server.ts` also pipes the whole stream but hardcodes
  `Content-Type: application/octet-stream`.
- The real difference was not the server code, it was the page origin: the old frontend was
  served over `http://` (web app + remote backend); the desktop now loads the frontend over
  `file://`. The asset bytes themselves are fine (the served file is byte-identical and a valid
  mp4).
- Worth doing regardless (but probably not the blank-video fix): make `asset-server` send the
  correct `Content-Type` (e.g. `video/mp4`) and support HTTP Range requests, so the player can
  stream/seek instead of the frontend downloading the whole file into a Blob. Diff `server.ts`
  vs `asset-server.ts` to see what got dropped.

### The `app://` custom protocol idea

- Tried it; it did not work — `<video>` was still rejected from an `app://` origin. A custom
  scheme is a dead end on its own.
- Relevant finding: in a minimal Electron test, video played from an `http://` origin but not
  from `file://` or `app://`. So if origin turns out to matter, the move is to serve the
  frontend over a real `http://localhost` server, not a custom scheme. Lower priority: only
  pursue if the dev:web test shows it is origin/Electron-specific.

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
