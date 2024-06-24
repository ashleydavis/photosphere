# Photosphere

This is the official ongoing monorepo for Photosphere, a cross-platform application for managing your photos and videos.

Photosphere is designed to be self-hosted and requires the following resources:
- Host the static web page.
- Host the Docker container.
- Provide a MongoDB database.
- Provide an AWS S3 bucket (other storage providers coming later).
- Provide an Auth0 account for authentication.

Contained herein are the code for Photosphere's:
- Backend
- Web frontend
- Electron app
- Android and iOS apps

Early development of Photosphere was covered in the book [Rapid Fullstack Development](https://rapidfullstackdevelopment.com/).

## Ingesting assets

Photos, videos and folders can be uploaded via the Upload page in the Web frontend.

Alternatively, [the upload script](./tools/upload/) can be used for bulk uploads.

To move assets from Google Photos:
- Use Google Takeout to export all your assets to a series of large zip files.
- Then use the upload script on the directory containing the zip files (it can unpack the zip file for you).

## Running Photosphere locally for development

### Pre-reqs

You need [Node.js](https://nodejs.org/) installed to run this code. Tested against Node.js v20+.

You need [Pnpm](https://pnpm.io/). It is used to install dependencies and manage the workspaces.

Install pnpm like this:

```bash
npm install -g pnpm
```

### Setup

First, clone a local copy of the code repository:

```bash
git clone git@github.com:ashleydavis/photosphere.git
```

Then install all dependencies at the root of the monorepo:

```
cd photosphere
pnpm install
```

### Compile shared components

Photosphere has TypeScript packages that are shared been components. 

You must compile them first:

```bash
pnpm run compile
```

To compile continously during development:

```bash
pnpm run compile:watch
```

### Start the components that you need

To start the backend, follow the instructions in [./backend/README.md](./backend/README.md).

To start the web-based frontend, follow the instructions in [./frontend/README.md](./frontend/README.md).

To start the Electron-based frontend, follow the instructions in [./electron/README.md](./electron/README.md).

To start the mobile frontend, follow the instructions in [./mobile/README.md](./mobile/README.md).









