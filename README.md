# Photosphere

Photosphere is a cross-platform application for managing your database of digital media files (photos and videos). I like to think of it as the spiritual successor to [Picasa](https://en.wikipedia.org/wiki/Picasa) but with a UI more like modern Google Photos and backed by a Git-style database for immutable binary files, like photos and videos, that have editable metadata.

Important features:
- Local first so you own it and you control it.
- Open source so you can understand what it does with your files.
- Maintain data sovereignty: the storage and privacy of your files are under your control.
- Build a corruption resistant database of your digital media files.
- Backup your database and keep your backup updated.
- Bidirectional synchronization between databases on different devices.
- Detect and repair corrupt files.
- Securely encrypt files that you store in the cloud vendor of your choice.
- Use the GUI to search, view and edit your photos and videos.

Photosphere is a local-first application available as:
- A CLI tool (build and manage databases from the command line) - grab it from the [releases page](https://github.com/ashleydavis/photosphere/releases).
- A desktop application app for Windows, macOS, and Linux - grab it from the [releases page](https://github.com/ashleydavis/photosphere/releases).
- A mobile application (Android and iOS apps - COMING SOON).

Visit the [Photosphere website](https://photosphere.codecapers.com.au/) to learn more.

Note: The self-hosted server option has been discontinued for now, but may be reinstated later if there's demand for it.

Contained herein are the code for Photosphere's:
- Desktop app
- Mobile apps
- CLI tool

Early development of Photosphere was covered in the book [The Feedback-Driven Developer](https://tfdd.codecapers.com.au/).

To get up and running, see the [wiki](https://github.com/ashleydavis/photosphere/wiki):
- [Installation - Desktop](https://github.com/ashleydavis/photosphere/wiki/Installation-Desktop)
- [Installation - CLI](https://github.com/ashleydavis/photosphere/wiki/Installation-CLI)
- [Getting Started - Desktop](https://github.com/ashleydavis/photosphere/wiki/Getting-Started-Desktop)
- [Getting Started - CLI](https://github.com/ashleydavis/photosphere/wiki/Getting-Started-CLI)

## Ingesting assets

You can ingest assets using either the desktop app or the CLI tool.

In the desktop app, use the Import page to drag and drop files or folders (it can unpack zip files for you), and they are added to your gallery automatically.

From the command line, use `psi add` to scan a directory and do bulk uploads (it can unpack zip files for you).

To move assets from Google Photos:
- Use Google Takeout to export all your assets to a series of large zip files.
- Then use `psi add` on the directory containing the zip files (it can unpack zip files for you).

To have Photosphere do it for you, switch on "Automatic import" in the desktop or mobile app's settings: it makes a private photo database for you, reads your photo folders or your phone's photo library, and takes in whatever is new. From the command line the same thing is `psi add --watch`, with `psi consolidate` to keep a remote copy in step. See [Automatic photo backup](docs/automatic-photo-backup.md).

## Bundled tools and licences

The desktop and CLI builds use ImageMagick and ffmpeg installed on the host system. The mobile apps (iOS and Android) instead bundle in-process builds of ImageMagick (ImageMagick licence) and ffmpeg (LGPL-2.1+), together with ImageMagick's libjpeg, libpng, and zlib delegates, so image and video processing works without system binaries. Full attribution and licences are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Photosphere's own code is MIT licensed (see [LICENSE](LICENSE)). To update the bundled versions, see [docs/updating-mobile-imagemagick-ffmpeg.md](docs/updating-mobile-imagemagick-ffmpeg.md) and `scripts/update-mobile-media-tools.sh`.

## Running Photosphere locally for development

After `bun install`, run `bun run setup` for the one-time, per-platform environment setup. It fans out to each package's own `setup` script (`bun --filter '*' setup`): the Android SDK toolchain on Linux/macOS and the iOS CocoaPods on macOS, each skipping cleanly where it does not apply. Install the git hooks (`bash scripts/install-hooks.sh`) and the pinned toolchain (`mise install`) separately. See [Development](docs/development.md) for the full walkthrough.

- [Development](docs/development.md) - Setup, the common commands, and how to run each app.
- [Testing](docs/testing/README.md) - Unit tests, CLI and Electron smoke tests, and the manual end-to-end scripts.
- [UI stories](packages/user-interface/src/stories/README.md) - Every page, modal, dialog, and component in isolation, and the story player that cycles them on desktop, Android, and iOS.

