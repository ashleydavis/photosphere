# Setting the build config

`set-build-config.sh` writes `packages/config/src/index.ts`, the file the app reads its version, commit hash, build date and nightly flag from. Those values are compiled into every frontend, so it runs before a build, never after one.

The checked-in file says `dev`, which is what a build made on your machine reports. A build handed to anyone else replaces it: a tagged release reports the tag with its leading `v` removed, and anything else reports `dev-nightly.<UTC timestamp>`, which is how the release workflow versions its nightly builds.

`apps/android-frontend/scripts/distribute-android.sh` uses it so a tester build carries a real version instead of `dev`, and puts the checked-in file back when the build is done.

## Using it

```
bash ./scripts/set-build-config.sh
bash ./scripts/set-build-config.sh --tag v0.0.9
```

The version goes to stdout and nothing else does, so a caller can capture it and label a build with it. What was written goes to stderr.

## Arguments

- `--tag <tag>` is the release tag being built, with or without its leading `v`. Without it, or with an empty one, the build is a nightly.
- `--commit <sha>` is the commit being built (default: the current HEAD).

## Putting the file back

This script only writes. The caller restores the checked-in file afterwards, because leaving it rewritten would put a stamped version into every later local build and show up as an uncommitted change to a tracked file.
