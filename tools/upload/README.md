# Upload

An upload tool for Photosphere.

Run this to upload local assets.

## Setup

Edit [./src/config.js](./src/config.js) with the paths to upload.

Set environment variable `GOOGLE_API_KEY` to your Google API key to enable reverse geocoding of GPS coordinates.

Install dependencies for the monorepo:

```bash
cd photosphere
pnpm install
```

## Image Magick

Certain files may require processing by Image Magick. Install it from here:

https://imagemagick.org/

Make sure the command `magick` is available from your path.

## Running the upload tool

Compile code:

```bash
pnpm run compile
```

Change into directory for the Upload tool and run it:

```bash
cd tools/upload
pnpm start
```

Run it for development with live reload:

```bash
pnpm run start:dev
```


 