# Releasing

Photosphere is built and released by one GitHub Actions workflow per platform, so a failure on one platform shows at a glance and holds up no other platform's release. Each workflow builds, tests and packages only its own platform and publishes its own GitHub release.

## The workflows and their tags

| Workflow | File | Release tag that starts it | GitHub release it creates | What the release holds |
| --- | --- | --- | --- | --- |
| Release Linux | `.github/workflows/release-linux.yml` | `linux-v1.2.3` | `linux-v1.2.3` | The Zig CLI (`.tar.gz`) and the Photosphere App for Linux (`.deb`, `.zip`) |
| Release Windows | `.github/workflows/release-windows.yml` | `windows-v1.2.3` | `windows-v1.2.3` | The Zig CLI (`.zip`) and the Photosphere App for Windows (MSI installer, `.zip`) |
| Release macOS arm64 | `.github/workflows/release-macos-arm64.yml` | `macos-arm64-v1.2.3` | `macos-arm64-v1.2.3` | The Zig CLI for Apple Silicon (`.tar.gz`) and the Photosphere App for Apple Silicon (`.dmg`, `.zip`) |
| Release macOS x64 | `.github/workflows/release-macos-x64.yml` | `macos-x64-v1.2.3` | `macos-x64-v1.2.3` | The Zig CLI for Intel (`.tar.gz`) and the Photosphere App for Intel (`.dmg`, `.zip`) |
| Release Android | `.github/workflows/release-android.yml` | `android-v1.2.3` | `android-v1.2.3` | The Photosphere App for Android (`.apk`) |
| Release iOS | `.github/workflows/release-ios.yml` | `ios-v1.2.3` | `ios-v1.2.3` | The Photosphere App for iOS (unsigned `.ipa`) |

The version the app reports is the tag with its platform prefix removed: `linux-v1.2.3` builds version `1.2.3`.

Each platform's versions are independent. Releasing `linux-v1.2.3` releases nothing on the other platforms; push a tag for each platform you want released.

A release workflow runs in two cases: when that platform's version tag is pushed, and for the nightly build.

The TypeScript is compiled and unit tested on Linux in every release workflow's `typescript-compile` and `typescript-unit-tests` jobs. The Zig unit tests run in its `zig-unit-tests` job on the workflow's own runner (Linux for Android, macOS for iOS).

## Test workflows

Each platform has a test workflow, `.github/workflows/test-<platform>.yml`, that runs on every push to a branch and when started from the Actions tab. It is that platform's release workflow without the `prepare-tag`, `package` and `create-release` jobs, so it builds and tests what a release would and publishes no release.

## Making a release

Push a tag for the platform:

```
git tag linux-v1.2.3
git push origin linux-v1.2.3
```

## Nightly builds

Every release workflow runs on a schedule at 1pm AEST (03:00 UTC) each day, on `main`. Its `prepare-tag` job checks for commits in the last 24 hours and skips every other job when there are none. The platform's nightly release is replaced each time: it is a prerelease named `<platform>-nightly` (for example `linux-nightly`), and its app reports the version `dev-nightly.<UTC timestamp>`.

## Release notes

The notes list the `cli:` commits made since that platform's previous release tag, from `scripts/release-notes.sh` with `--tag-pattern "<platform>-v*.*.*"`. See [its own file](../scripts/release-notes.md).
