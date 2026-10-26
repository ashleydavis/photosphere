# Setting the build config

`set-build-config.sh` writes `packages/config/src/index.ts`, the file the app reads its version, commit hash, build date and nightly flag from. Those values are compiled into every frontend, so it runs before a build, never after one.

It stamps the same values into the Zig config files, `packages-zig/config-zig/src/index.zig` and `apps/cli-zig/src/lib/config.zig`, so a Zig build reports the same version as the TypeScript one. Only the lines holding the version, commit hash, build date and nightly flag are rewritten, and the script fails if one of them is missing afterwards. It also refuses a version or commit with characters other than letters, digits and `. _ + -`, because they are written into Zig string literals.

It writes the version into the `.version` of the root `app.zon` as well, which Ziggy writes in the app's log files. The checked-in value is `dev`.

The checked-in files say `dev`, which is what a build made on your machine reports. A build handed to anyone else replaces it: a tagged release reports the version from its tag (the release workflows strip the platform prefix, so `linux-v1.2.3` reports `1.2.3`), and anything else reports `dev-nightly.<UTC timestamp>`, which is how the release workflow versions its nightly builds.

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

The release workflow calls it in every job that builds the app, with the release tag for a release and without one for a nightly.

## Putting the files back

This script only writes. The caller restores the checked-in files (the TypeScript one, both Zig ones and `app.zon`) afterwards, because leaving them rewritten would put a stamped version into every later local build and show up as an uncommitted change to tracked files.
