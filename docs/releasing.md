# Releasing

Photosphere is built and released by one GitHub Actions workflow per platform, so a failure on one platform shows at a glance and holds up no other platform's release. Each workflow builds, tests and packages only its own platform and publishes its own GitHub release.

## The workflows and their tags

| Workflow | File | Release tag that starts it | GitHub release it creates | What the release holds |
| --- | --- | --- | --- | --- |
| Release Zig Linux | `.github/workflows/release-zig-linux.yml` | `linux-v1.2.3` | `zig-linux-v1.2.3` | The Zig CLI (`.tar.gz`) and the Photosphere App for Linux (`.deb`, `.zip`) |
| Release Zig Windows | `.github/workflows/release-zig-windows.yml` | `windows-v1.2.3` | `zig-windows-v1.2.3` | The Zig CLI (`.zip`) and the Photosphere App for Windows (MSI installer, `.zip`) |
| Release Zig macOS | `.github/workflows/release-zig-macos.yml` | `macos-v1.2.3` | `zig-macos-v1.2.3` | The Zig CLI for Intel and Apple Silicon (`.tar.gz`) and the Photosphere App for both (`.dmg`, `.zip`) |
| Release Zig Android | `.github/workflows/release-zig-android.yml` | `android-v1.2.3` | `zig-android-v1.2.3` | The Photosphere App for Android (`.apk`) |
| Release Zig iOS | `.github/workflows/release-zig-ios.yml` | `ios-v1.2.3` | `zig-ios-v1.2.3` | The Photosphere App for iOS (unsigned `.ipa`) |

The version the app reports is the tag with its platform prefix removed: `linux-v1.2.3` builds version `1.2.3`.

Each platform's versions are independent. Releasing `linux-v1.2.3` releases nothing on the other platforms; push a tag for each platform you want released.

The TypeScript release workflow (`.github/workflows/release-typescript.yml`) is disabled in GitHub and does not run.

For now the release workflows run only when started manually from the Actions tab: their push and pull request triggers, release tag pushes included, are commented out until every platform's workflow passes. Until then a pushed tag starts nothing, and pushes and pull requests build no nightly.

The unit tests (TypeScript and Zig) are not part of any release workflow. They run in the Zig CI workflow (`.github/workflows/ci-zig.yml`), on Linux, for every push to a branch, every pull request into `main` and every manual run.

## Making a release

Push a tag for the platform:

```
git tag linux-v1.2.3
git push origin linux-v1.2.3
```

Or run the platform's workflow manually from the Actions tab and pick a release action:

- `none` builds a nightly (see below).
- `new-patch` creates the next patch tag for that platform (`linux-v1.2.3` becomes `linux-v1.2.4`), pushes it and releases it.
- `update-latest` moves that platform's newest tag to the commit being built and releases it again.

## Nightly builds

Every push to a branch, every pull request into `main` and every manual run with `none` builds a nightly. The platform's nightly release is replaced each time: it is a prerelease named `zig-<platform>-nightly` (for example `zig-linux-nightly`), and its app reports the version `dev-nightly.<UTC timestamp>`.

## Release notes

The notes list the `cli:` commits made since that platform's previous release tag, from `scripts/release-notes.sh` with `--tag-pattern "<platform>-v*.*.*"`. See [its own file](../scripts/release-notes.md).
