# Photosphere

This is the official ongoing monorepo for Photosphere, a cross-platform application for managing your photos and videos.

Photosphere is designed to be self-hosted and requires the following resources:
- Host the Docker container
- Provide S3 compatible storage (I used Digital Ocean Spaces, but also works with AWS S3)
- For authentication, use an API key or provide an Auth0 account for authentication.

Contained herein are the code for Photosphere's:
- Backend
- Web frontend
- CLI tool
- Electron app
- Android and iOS apps

Early development of Photosphere was covered in the book [The Feedback-Driven Developer](https://www.manning.com/books/the-feedback-driven-developer).

## Ingesting assets

Photos, videos and folders can be uploaded via the Upload page in the Web frontend.

Alternatively, use the CLI tool `psi add` to scan a direcotry and do a bulk uploads.

To move assets from Google Photos:
- Use Google Takeout to export all your assets to a series of large zip files.
- Then use the upload script on the directory containing the zip files (it can unpack the zip file for you).

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
    - apps - Top level apps live here (frontend, backend, mobile, Electron, cli tool)
    - packages - Shared code libraries.
    - test - Data for testing.


### Compile the project

THIS STEP IS OPTIONAL

You don't have to compile the project before doing a build. You only should do this step if you change the code and want to make sure the TypeScript code still compiles after you change.

```bash
bun run compile
```

### Start the components that you need

To start the backend, follow the instructions in [./apps/backend/README.md](./apps/backend/README.md).

To start the web-based frontend, follow the instructions in [./apps/frontend/README.md](./apps/frontend/README.md).

To start the Electron-based frontend, follow the instructions in [./electron/README.md](./apps/electron/README.md).

To start the mobile frontend, follow the instructions in [./apps/mobile/README.md](./apps/mobile/README.md).







