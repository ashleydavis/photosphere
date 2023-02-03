# Photosphere frontend

This is the frontend for [the Photosphere application](https://rapidfullstackdevelopment.com/example-application). Built on [React](https://reactjs.org/) and bundled with [Parcel](https://parceljs.org/).

## Pre-reqs

You need [Node.js](https://nodejs.org/) installed to run this code.

To run this frontend you must first run the backend in the directory `../backend`.

## Setup

Open a terminal and change directory to the frontend project:

```bash
cd photosphere-monorepo/frontend
```

Install dependencies:

```bash
npm install
```

## Run the Parcel dev server

Run the dev server like this:

```bash
npm start
```

Then click the link or point your browser at the default location for Parcel: [http://localhost:1234](http://localhost:1234).

## Build the static web page

Build the project to a static web page like this:

```bash
npm run build
```

The static web page is output to the `dist` subdirectory.

## Test the static web page

After building the static web page, you can test it locally using `live-server`.

First install live-server globally:

```bash
npm install -g live-server
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
npm test
```

## Run e2e tests

```bash
npm run test-e2e
``` 

Enable this to debug with Playwright:

```bash
export PWDEBUG=1
```

Or on Windows:

```bash
set PWDEBUG=1
```

## Environment variables

- `GOOGLE_API_KEY` - Set to a valid Google API key to enable reverse geocoding of photo location in the browser.