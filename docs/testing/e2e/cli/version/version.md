# CLI Manual Test: Version

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `version` prints the CLI's version and the versions of what it depends on.

## Prep

From the repo root, build the CLI and put it on the PATH:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
```

Expected: no output.

## Test

### 1. Print the version

```bash
psi version
```

Expected:
- The psi version is printed, with the versions of the media tools.
- The command exits successfully.

## Check

The version output in step 1 is the check.
