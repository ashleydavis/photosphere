# Photosphere web frontend

This is the web frontend for [the Photosphere application](https://rapidfullstackdevelopment.com/example-application). Built on [React](https://reactjs.org/) and bundled with [Webpack](https://webpack.js.org/).

## Setup

First, follow the instructions in [the main readme](../README.md).

Then open a terminal and change directory to the frontend project:

```bash
cd frontend
```

To enable the frontend you must also run the [backend](../backend/README.md).

## Run the Webpack dev server

Run the dev server like this:

```bash
pnpm start
```

Then click the link or point your browser at the default location for Webpack: [http://localhost:8080](http://localhost:8080).

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

## Run e2e tests

```bash
pnpm run test-e2e
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

- `BASE_URL` - Sets the URL for the connection to the backend.
- `GOOGLE_API_KEY` - Sets to a valid Google API key to enable reverse geocoding of photo location in the browser.

### Auth0 authentication details:

- `AUTH0_DOMAIN`
- `AUTH0_CLIENT_ID`
- `AUTH0_AUDIDENCE`