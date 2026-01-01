# Photosphere

Photosphere is a cross-platform application for managing your database of digital media files (photos and videos). I like to think of it as the spiritual successor to [Picasa](https://en.wikipedia.org/wiki/Picasa) but with a UI more like modern Google Photos and backed by a Git-style database for immutable binary assets like photos and videos that have editable metadata.

Important features:
- Build a corruption resistant database of your digital media files.
- Backup your database and keep your backup updated.
- Detect and repair corrupt files.
- Securely encrypt files that you store in the cloud.
- Use the UI to search, view and edit your photos and videos.

Photosphere can be run locally or self-hosted as a server:
- Run it locally using the CLI tool (build and view databases on your desktop computer).
- Host the Docker container and make your files available over the internet.
- Provide S3 compatible storage (I used Digital Ocean Spaces, but also works with AWS S3).
- For authentication, use an API key or provide an Auth0 account for authentication.

Contained herein are the code for Photosphere's:
- Backend
- Web frontend
- CLI tool
- Electron app
- Android and iOS apps

Early development of Photosphere was covered in the book [The Feedback-Driven Developer](https://www.manning.com/books/the-feedback-driven-developer).

See the [wiki](https://github.com/ashleydavis/photosphere/wiki) for installation and getting started.

## Ingesting assets

Photos, videos and folders can be uploaded via the Upload page in the Web frontend.

Alternatively, use the CLI tool `psi add` to scan a directory and do bulk uploads. Use `psi summary` to view database statistics, `psi verify` to check integrity, `psi replicate` to create backups, and `psi compare` to verify backup consistency.

To move assets from Google Photos:
- Use Google Takeout to export all your assets to a series of large zip files.
- Then use `psi add` on the directory containing the zip files (it can unpack zip files for you).

## Running Photosphere locally for development

### Pre-reqs

You need [Bun](https://bun.sh/docs/installation) installed to run this code. Tested against Bun v1.2.11 on Ubuntu Linux, Windows 10/11 and MacOS.

### Setup

First, clone a local copy of the code repository:

```bash
git clone git@github.com:ashleydavis/photosphere.git
```

Then install all dependencies at the root of the monorepo:

```
cd photosphere
bun install
```

## Project layout

- photosphere/
    - apps - Top level apps live here (frontend, backend, mobile, Electron, cli tool, dev-server)
    - packages - Shared code libraries.
    - test - Data for testing.


### Compile the project

THIS STEP IS OPTIONAL

You don't have to compile the project before doing a build. You only should do this step if you change the code and want to make sure the TypeScript code still compiles after your change.

```bash
bun run compile
```

### Start the components that you need

To run the CLI tool, follow the instructions in [./apps/cli/README.md](./apps/cli/README.md).

To start the backend, follow the instructions in [./apps/backend/README.md](./apps/backend/README.md).

To start the web-based frontend, follow the instructions in [./apps/frontend/README.md](./apps/frontend/README.md).

To start the dev-server (WebSocket development server), follow the instructions in [./apps/dev-server/README.md](./apps/dev-server/README.md).

To start the Electron-based frontend, follow the instructions in [./electron/README.md](./apps/electron/README.md).

To start the mobile frontend, follow the instructions in [./apps/mobile/README.md](./apps/mobile/README.md).







