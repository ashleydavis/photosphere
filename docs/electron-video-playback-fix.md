# Electron video playback fix (minimal, verified)

> **Make minimal changes to the code.** Apply ONLY the three changes listed in this document and
> nothing else. Do not refactor, restyle, rename, or "improve" anything nearby. The goal is a diff
> that contains exactly these changes and nothing unexpected, so it can be reviewed line by line.
> If you think something else also needs changing, stop and raise it separately rather than folding
> it into this diff.
>
> **Do NOT change the styling of the video element or the box that contains it.** Leave the
> `<video>` element's `className`/`style` exactly as it is, and do not touch the carousel item /
> container that wraps it. These changes are about making the video *play*, not about how it is
> sized or positioned. Sizing and layout are out of scope for this doc.

## What this fixes

In the Electron desktop build, imported videos open the full-screen viewer but show nothing:
no picture, no controls, just the background. Photos work. Videos work fine in the web build
(`bun run dev:web`).

This document is the **minimal set of changes** to make video play in the Electron build. Each
change was verified necessary by ablation testing (removing it brings the bug back). Apply all
three.

## Why it breaks (two separate bugs, stacked)

You must understand both, because fixing only one still looks "broken":

1. **The video source is rejected (nothing loads).** The desktop page is served from a `file://`
   origin. The frontend hands `<video>` a `blob:file://…` URL. Chromium's media URL-safety check
   rejects a `blob:` URL created from a `file://` origin, so the element never gets a source. (This
   is media-specific: the same `blob:file://` works for `<img>`, which is why photos display but
   videos do not.)

2. **Even once it loads, the video paints black.** After fix #1 the video decodes fine (reaches
   `canplay`) but renders solid black. On Linux Electron this is a GPU video-compositing problem,
   unrelated to the source.

The fix for #1 is to give `<video>` an `http://localhost` URL instead of a blob. The fix for #2 is
to disable hardware acceleration.

## The three changes

### Change 1 — disable hardware acceleration

Fixes the black picture (bug #2).

File: `apps/desktop/src/main.ts`

Add this at module top level (after the imports, before the app starts up). Anywhere before the
window is created is fine; placing it next to the other top-level setup is cleanest:

```ts
// Video decodes (canplay) but paints black on Linux Electron: a GPU video-compositing problem.
// Disabling hardware acceleration forces video to composite on the CPU, which paints correctly.
// Must run before app is ready.
app.disableHardwareAcceleration();
```

### Change 2 — serve desktop video over http instead of a blob

Fixes the rejected source (bug #1). On the desktop (`file://` page) point `<video src>` at the
existing http asset endpoint; on web keep the blob (it works there).

File: `packages/user-interface/src/components/video.tsx`

The component already loads the asset into a blob and renders `<video src={objectURL}>`. Change it
to detect the desktop and use the http asset URL instead. The full file after the change:

```tsx
import React, { useEffect, useState } from "react";
import { log } from "utils";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";
import { useAssetDatabase } from "../context/asset-database-source";

export interface IVideoProps {
    //
    // The asset being displayed.
    //
    asset: IGalleryItem;
}

//
// Renders a video.
//
export function Video({ asset }: IVideoProps) {

    const [objectURL, setObjectURL] = useState<string>("");

    const { loadAsset, unloadAsset } = useGallery();
    const { assetUrl } = useAssetDatabase();

    //
    // On the Electron desktop build the page is served from a file:// origin, where a
    // blob:file:// media URL is rejected by Chromium's media URL-safety check (the video goes
    // blank). In that case point the <video> directly at the http asset URL instead, which is the
    // same media origin that plays in the web build. On web (http origin) keep using the blob.
    //
    const useDirectUrl = window.location.protocol === "file:";

    useEffect(() => {
        if (useDirectUrl) {
            //
            // No blob is loaded for the direct-URL path, so there is nothing to load or unload.
            //
            return;
        }

        loadAsset(asset._id, "asset")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setObjectURL(assetLoaded.objectUrl);
                }
            })
            .catch(err => {
                log.exception(`Failed to load video asset: ${asset._id}`, err as Error);
            });

        return () => {
            unloadAsset(asset._id, "asset");
        };
    }, [asset]);

    //
    // The media source: the direct http asset URL on desktop (file:// origin), otherwise the
    // loaded blob URL on web.
    //
    const videoSrc = useDirectUrl
        ? assetUrl(asset._id, "asset")
        : objectURL;

    return (
        <>
            {videoSrc
                && <video
                    className="w-full h-full"
                    muted={true}
                    autoPlay={true}
                    controls={true}
                    loop={true}
                    src={videoSrc}
                    />
            }
        </>
    );
};
```

Notes:
- `assetUrl(assetId, assetType)` already exists on the asset-database context
  (`packages/user-interface/src/context/asset-database-source.tsx`). It returns
  `http://localhost:<port>/asset?id=…&type=…&db=…`, which the desktop REST API already serves (it is
  the same endpoint the blob path fetches its bytes from).
- The `useDirectUrl` check (`window.location.protocol === "file:"`) is what scopes this to the
  Electron build. The web build is `http:` and is left untouched.

### Change 3 — allow http media in the desktop Content Security Policy

Without this the CSP blocks the `http://localhost` media URL from Change 2.

File: `apps/desktop-frontend/index.html`

In the `<meta http-equiv="Content-Security-Policy" …>` tag, add a `media-src` directive that allows
`http://localhost:*`. Insert it into the existing `content` string (for example, right after the
`img-src` directive):

```
media-src 'self' http://localhost:*;
```

This file is the desktop frontend's HTML only; the web build uses a different
`index.html` (`apps/dev-frontend/index.html`) and is unaffected.

## What is NOT needed

If you read older notes in this repo, ignore these dead ends. They were tried and proven
unnecessary by ablation:

- A custom privileged protocol scheme (e.g. `app://` / `psphere://`) with
  `protocol.registerSchemesAsPrivileged` + `protocol.handle` + `net.fetch`. Plain `http://localhost`
  works once hardware acceleration is disabled.
- Sending a real media `Content-Type` from the asset server (it can stay
  `application/octet-stream`).
- Changing the page origin away from `file://`.
- Adding `blob:` or a custom scheme to the CSP `media-src`.

## How to verify

1. Build and run the desktop app: `bun run dev`.
2. Open an imported video in the full-screen viewer.
3. The video should display and auto-play with controls.

To confirm both bugs are really covered (optional):
- Temporarily remove Change 1 → the video loads but is black (proves Change 1 is needed).
- Temporarily revert Change 2 to the blob → the video shows nothing (proves Change 2 is needed).

Judge visibility only in the real GUI. A headless screenshot can show a frame the real GPU will not
paint, so it is not a reliable test for this bug.

## Known limitation / follow-up

The asset endpoint streams the whole file without HTTP Range support (no `Accept-Ranges` /
`206 Partial Content`). Video plays start-to-finish, but seeking may be limited. Adding Range
support to `GET /asset` in `packages/rest-api/src/lib/asset-server.ts` is a separate improvement.
</content>
