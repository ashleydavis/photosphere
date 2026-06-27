# Step 6: Add native media host functions (stubbed)

Add the media host-function surface so pure handlers run end to end first while media handlers remain explicitly unfinished but loud.

## What to do

1. Declare the media host functions on both platforms: `host.imageResize`, `host.videoTranscode`, `host.ffprobe`.
2. Until each is real, it stays `stubbed`: its body throws the exact NOT IMPLEMENTED message (via the `notImplemented` helper from Step 5).
3. Define their signatures to take input/output storage paths and never raw bytes to/from JS (consistent with the large-blob file-handle rule from Step 4).
4. Update `docs/mobile-host-bridge-checklist.md` to list these functions as `stubbed` on iOS and Android.

This ordering ensures pure handlers (hash / check / verify / db reads / sync) work before any media tool is implemented.

## Tests

- Native test on both platforms: each media host function, while stubbed, throws the exact NOT IMPLEMENTED message and logs it (reuses the guard test pattern from Step 5, one case per media function).

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
