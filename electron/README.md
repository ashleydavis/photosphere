# Photosphere Electron

The Electron-based desktop version of [the Photosphere application](https://rapidfullstackdevelopment.com/example-application).

## Pre-reqs

To run the Electron version of Photosphere you must first run the backend (`../backend`) and the Electron-specific frontend (`./frontend`).

## Setup

First, follow the instructions in [the main readme](../README.md).

Then open a terminal and change directory to the Electron project:

```bash
cd electron
```

To enable the frontend you must also run the [backend](../../backend/README.md).

## Run from the dev server

If you are running the Electron frontend in dev mode, start the Electron app like this:

```bash
npm run start:dev
```

## Run from the static web page

If you built the Electron frontend to a static webage, start the Electron app like this:

```bash
npm start
```

