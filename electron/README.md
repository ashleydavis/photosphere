# Photosphere Electron

The Electron-based desktop version of the Photosphere application.

## Pre-reqs

To run the Electron version of Photosphere you must first run [the backend](../backend/README.md).

## Setup

First, follow the instructions in [the main readme](../README.md).

Then open a terminal and change directory to the Electron project:

```bash
cd electron
```

See the [Electron frontend readme](./frontend/README.md) for the environment variables you need for the Electron frontend.

## Run from the dev server

If you are running the Electron frontend in dev mode, start the Electron app like this:

```bash
bun run start:dev
```

This command also starts the dev server.

## Run from the static web page

To build the Electron frontend to a static web page, start the Electron app like this:

```bash
bun run start
```

This command also builds the static version of the web page.

## Build the installer

Run build script for each platform:

```bash
bun run build-win
bun run build-linux
bun run build-mac
```

For MacOS you need to build it on a Mac.

Results can be found under `./tmp/build`.