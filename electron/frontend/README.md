# Photosphere frontend

This is the frontend for [the Photosphere application](https://rapidfullstackdevelopment.com/example-application). Built on [React](https://reactjs.org/) and bundled with [Parcel](https://parceljs.org/).

## Pre-reqs

You need [Node.js](https://nodejs.org/) installed to run this code.

To run this frontend you must first run the backend in the directory `../backend`.

## Setup

Open a terminal and change directory to the frontend project:

```bash
cd photosphere-monorepo/electron/frontend
```

Install dependencies:

```bash
pnpm install
```

## Run the Parcel dev server

Run the dev server like this:

```bash
pnpm start
```

Then click the link or point your browser at the default location for Parcel: [http://localhost:1234](http://localhost:1234).

## Build the static web page

Set the BASE_URL environment variable to point the frontend to the backend:

```bash
export BASE_URL=http://localhost:3000
```

Or on Windows:

```bash
set BASE_URL=http://localhost:3000
```

Build the project to a static web page like this:

```bash
pnpm run build
```

The static web page is output to the `dist` subdirectory.

## Test the static web page

After building the static web page, you can test it locally using `live-server`.

First install live-server globally:

```bash
pnpm install -g live-server
```

Now change into the directory where the static web page is generated:

```bash
cd dist
```

From here, start live-server:

```bash
live-server
```

The web page should automatically be displayed in your browser.

## Run automated tests

```bash
pnpm test
```

## Environment variables

- `BASE_URL` - Sets the URL for the connection to the backend.
- `GOOGLE_API_KEY` - Sets to a valid Google API key to enable reverse geocoding of photo location in the browser.