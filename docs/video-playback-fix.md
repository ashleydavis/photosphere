# Video playback fix (Electron) — what actually fixed it

Imported videos showed a blank/black player in the Electron desktop build (they worked in
`dev:web`). This is the confirmed, working fix. There were **two separate bugs stacked on top of
each other**, and both had to be fixed. Fixing either one alone left the video broken, which is why
earlier single-fixes kept "not working".

## The two root causes

1. **The media source was rejected (not loading).** The desktop page is served from a `file://`
   origin. The frontend handed `<video>` a `blob:file://…` URL (from `URL.createObjectURL`).
   Chromium's media URL-safety check rejects a `blob:` URL minted from a `file://` origin, so the
   element never got a source (`readyState 0`, error `Media load rejected by URL safety check`).
   Note: this is media-specific. The same `blob:file://` works for `<img>`, which is why photos
   displayed but videos did not.

2. **Even once it loaded, the video painted black (loads but does not paint).** After fix #1 the
   video reached `canplay` (decoded fine), but the picture rendered solid black. On Linux Electron
   this is a GPU video-compositing problem, independent of the source.

## The fix

### Part 1 — serve video through a privileged custom scheme (fixes "not loading")

Instead of a `blob:file://` URL, the desktop serves video over a registered privileged scheme
`psphere://`, and points `<video src>` at that scheme. This mirrors the reference app
(`BillelMessaadi/electronjs-local-video-player`), which uses an `app://` scheme. A privileged
`secure` + `standard` + `stream` scheme is treated as a first-class, streamable media source where
a `blob:file://` URL is not.

`apps/desktop/src/main.ts`:

- Import `protocol` and `net` from `electron`.
- Register the scheme as privileged **before app is ready** (top level of the module):

  ```ts
  protocol.registerSchemesAsPrivileged([
      {
          scheme: 'psphere',
          privileges: {
              standard: true,
              secure: true,
              supportFetchAPI: true,
              stream: true,        // required for <video>/<audio> streaming + seeking
              bypassCSP: true,
          },
      },
  ]);
  ```

- Handle the scheme **after the REST API has started** (inside `app.whenReady()`, right after
  `await initRestApi()`), proxying to the existing Express `/asset` endpoint with `net.fetch`. This
  keeps asset bytes flowing through the storage abstraction (encrypted / S3 / fs) instead of reading
  a raw file from disk:

  ```ts
  protocol.handle('psphere', (request) => {
      if (restApiPort === null) {
          return new Response('REST API not ready', { status: 503 });
      }
      const requestUrl = new URL(request.url);
      const assetId = requestUrl.searchParams.get('id') || '';
      const assetType = requestUrl.searchParams.get('type') || '';
      const databasePath = requestUrl.searchParams.get('db') || '';
      const contentType = requestUrl.searchParams.get('contentType') || '';
      const target = `http://localhost:${restApiPort}/asset`
          + `?id=${encodeURIComponent(assetId)}`
          + `&type=${encodeURIComponent(assetType)}`
          + `&db=${encodeURIComponent(databasePath)}`
          + `&contentType=${encodeURIComponent(contentType)}`;
      return net.fetch(target);
  });
  ```

`packages/rest-api/src/lib/asset-server.ts` (GET `/asset`): send a real media `Content-Type` when
the caller passes a `contentType` query param (a direct `<video src>` needs a real media type to
play; a blob carried its own type). Falls back to `application/octet-stream` when absent.

`packages/user-interface/src/components/video.tsx`: on the Electron desktop (detected via
`window.location.protocol === "file:"`) build a `psphere://` URL and use it as `src`, instead of the
blob:

```ts
const schemeUrl = assetUrl(asset._id, "asset").replace(/^https?:\/\/[^/]+\/asset/, "psphere://asset");
const videoSrc = `${schemeUrl}&contentType=${encodeURIComponent(asset.contentType)}`;
```

`apps/desktop-frontend/index.html`: allow the scheme in the CSP `media-src`:

```
media-src 'self' http://localhost:* psphere:;
```

### Part 2 — disable hardware acceleration (fixes "black picture")

`apps/desktop/src/main.ts`, **before app is ready** (top level of the module):

```ts
app.disableHardwareAcceleration();
```

This forces video to composite on the CPU, which paints correctly. Without it the video decoded
(`canplay`) but stayed black.

## Why earlier attempts failed

- **Adding CSP `media-src` alone** did not help: the `blob:file://` URL is rejected by the media
  URL-safety check regardless of CSP. CSP was a red herring on its own.
- **Switching the frontend origin (`app://` experiment)** did not help and muddied the picture: the
  page origin was never the blocker. The reference app also loads its page from `file://`. What
  matters is the **scheme of the video `src`**, not the page origin.
- **`disableHardwareAcceleration()` had been tried earlier and dismissed** as a dead end. That test
  happened while the source was still being rejected (nothing decoded), so disabling the GPU could
  not have shown anything. It only became relevant once Part 1 made the video actually decode.
- This is the key trap: with two stacked bugs, fixing only Part 1 gives a black `canplay` video, and
  fixing only Part 2 gives a rejected source. Each fix alone looks like "still broken".

## How we proved it (the step that broke the deadlock)

We stopped guessing and instrumented `video.tsx` with an on-screen debug overlay that printed the
live `<video>` lifecycle: `useDirectUrl`, the exact `src`, and the element's status
(`loadstart → loadedmetadata → canplay`, or `ERROR: …`). Running the real GUI showed
`status=canplay` with a black picture. That single fact flipped the diagnosis from case A (not
loading) to case B (loads but does not paint) and pointed straight at GPU compositing. Judge
visibility only in the real GUI, never a headless screenshot.

## Follow-ups (not required for the fix, but worth doing)

- **Remove the temporary debug overlay** in `packages/user-interface/src/components/video.tsx`
  (the magenta/yellow borders, the green status line, and the `debugStatus` state + `onLoadStart` /
  `onLoadedMetadata` / `onCanPlay` / `onError` handlers).
- **Narrow the GPU fix.** `disableHardwareAcceleration()` is global and can slow the whole app. Try
  replacing it with a lighter switch that keeps GPU for everything except video, e.g.
  `app.commandLine.appendSwitch('disable-gpu-compositing')` or
  `app.commandLine.appendSwitch('disable-accelerated-video-decode')`, and confirm the video still
  paints.
- **Add HTTP Range support** to `/asset` so video seeking works smoothly (currently the whole
  stream is piped without `Accept-Ranges` / `206 Partial Content`).
- **Web vs desktop split.** The web build still uses the blob path (it works there). The desktop
  path is gated on `window.location.protocol === "file:"`.
</content>
</invoke>
