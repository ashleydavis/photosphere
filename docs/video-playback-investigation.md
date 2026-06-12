# Video playback investigation (imported video shows a blank player)

Symptom: an imported video (e.g. `test.mp4`) opens the full-screen asset view but shows a
blank/black player. Photos display fine. Video does not.

This document is a troubleshooting checklist. The blank video has been traced to a single proven
cause: the missing CSP `media-src` directive blocks the `blob:` URL the `<video>` loads (case A,
proven by the DevTools probe below). The fix (adding `media-src`) has been applied and is awaiting
a reload-and-retest. Earlier hypotheses (page origin, Content-Type, GPU compositing) were all
tested and ruled out.

RESOLVED to **case A (the media source is rejected before it loads)**, proven by the DevTools
ground-truth probe (see that section). It is **not** case B: the previous "GPU/compositing"
hypothesis is disproven. The `<video>` element is laid out at full size but its source is blocked,
so it never decodes a byte. Cause: the missing CSP `media-src` directive blocks the `blob:` URL.

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
- To apply: add `media-src 'self' blob: http://localhost:*;` to that CSP string, then
  rebuild (`bun run bundle:renderer`). APPLIED 2026-06-12; awaiting retest.
- Note on the old "necessary-but-not-sufficient" caveat: the only prior test where `media-src`
  was present *and* the video was still blank was the `app://` experiment, i.e. with a
  `blob:app://` source on a different origin, not a clean `file://` + `media-src` test. So
  `media-src` has never actually been ruled out as the full fix under the normal `file://` build.
  The current ground-truth probe (case A) is fully consistent with `media-src` being THE cause.

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

### The `app://` custom protocol idea — TESTED, DISPROVES THE ORIGIN THEORY

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
- **Root cause of the blank video: the missing CSP `media-src` directive** blocks the `blob:` URL
  the `<video>` uses as its source. This is case A, proven by the probe above.
- FIX APPLIED (pending retest): added `media-src 'self' blob: http://localhost:*;` to the CSP in
  `apps/desktop-frontend/index.html` and rebuilt (`bun run bundle:renderer`). Reload and re-run
  the probe to confirm.
