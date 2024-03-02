# Electron

The Electron-based desktop version of [the Photosphere application](https://rapidfullstackdevelopment.com/example-application).

## Pre-reqs

To run the Electron version of Photosphere you must first run the backend (`../backend`) and the Electron-specific frontend (`./frontend`).

## Setup

Open a terminal and change directory to the Electron project:

```bash
cd photosphere-monorepo/electron
```

Install dependencies:

```bash
pnpm install
```

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

