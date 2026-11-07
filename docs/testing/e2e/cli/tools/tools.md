# CLI Manual Test: Tools

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `tools` reports the media tools the CLI needs and whether each was found.

## Prep

From the repo root, build the CLI and put it on the PATH:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
```

Expected: no output.

## Test

### 1. Check the tools

```bash
psi tools --yes
```

Expected:
- ImageMagick, ffmpeg and ffprobe are each listed with a version and shown as found.
- The command exits successfully.

## Check

The tools output in step 1 is the check.
