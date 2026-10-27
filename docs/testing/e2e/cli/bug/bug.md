# CLI Manual Test: Bug Report

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `bug` builds a bug report with system information, without opening a browser when told not to.

`bug` only builds a GitHub "new issue" link. Nothing is posted unless that link is opened and submitted, so do not submit it.

## Prep

From the repo root, build the CLI and put it on the PATH:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
```

Expected: no output.

## Test

### 1. Generate a bug report without opening a browser

```bash
psi bug --no-browser --yes
```

Expected:
- The report shows system information (operating system, psi version, tool versions).
- A `https://github.com/ashleydavis/photosphere/issues/new` link is printed.
- No browser window opens, and the command exits successfully.

## Check

The bug output in step 1 is the check.
