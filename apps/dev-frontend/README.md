# Photosphere dev-frontend

This is the development frontend for the Photosphere application. Built on [React](https://reactjs.org/) and bundled with [Vite](https://vitejs.dev/).

## Project Structure

```
dev-frontend/
├── src/
│   ├── index.tsx                              # React entry point
│   ├── app.tsx                                # Main app component
│   ├── tailwind.css                           # Tailwind CSS
│   ├── lib/
│   │   ├── task-queue-provider-websocket.ts   # WebSocket task queue provider
│   │   ├── worker-backend-websocket.ts        # WebSocket worker backend
│   │   └── use-web-socket.ts                  # WebSocket hook
│   └── test/
│       └── e2e/
│           └── frontend.test.ts               # E2E tests
├── index.html                                 # HTML template
├── package.json
├── vite.config.ts                             # Vite configuration
├── tailwind.config.js                         # Tailwind configuration
├── postcss.config.js                          # PostCSS configuration
└── tsconfig.json
```

## Setup

First, follow the instructions in [the main readme](../../README.md).

Then open a terminal and change directory to the dev-frontend project:

```bash
cd apps/dev-frontend
```

To enable the frontend you must first run the [dev-server](../dev-server/README.md).

## Run the Vite dev server

Run the dev server like this:

```bash
bun start
```

Then click the link or point your browser at the default location for Vite: [http://localhost:8080](http://localhost:8080).

## Build the static web page

Set the VITE_BASE_URL environment variable to point the frontend to the backend:

```bash
export VITE_BASE_URL=http://localhost:3000
```

Or on Windows:

```bash
set VITE_BASE_URL=http://localhost:3000
```

Build the project to a static web page like this:

```bash
bun run build
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

## Run the frontend locally in production mode

Compile the whole project:

```bash
bun run compile
```

Compile in watch mode in another terminal, if you want to make changes to the code while it is running:

```bash
bun run compile:watch
```

Set environment variables:

```bash
export VITE_BASE_URL=<photosphere-api-url>
```

Run it in prod mode:

```bash
cd photosphere/dev-frontend
bun run start:prod
```

## Run automated tests

```bash
bun test
```

## Run e2e tests

```bash
bun run test-e2e
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

- `VITE_NODE_ENV` - Set to "production" for production use.
- `VITE_BASE_URL` - Sets the URL for the connection to the backend.

