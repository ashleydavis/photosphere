# Dev-server

A development server with for the Dev-frontend that's faster than developing directly wiht Electron.

## Project Structure

```
dev-server/
├── src/
│   ├── index.ts                              # Server entry point
│   └── lib/
│       ├── task-queue-provider-inline.ts     # Inline task queue provider
│       └── worker-backend-inline.ts          # Inline worker backend
├── package.json
└── tsconfig.json
```

## Features

- WebSocket server running on port 3001
- Bidirectional message exchange with the frontend
- TypeScript support

## Usage

### Start the server

```bash
bun run start
```

Or for development with hot reload:

```bash
bun run dev
```

## Development

- Compile TypeScript: `bun run compile`
- Watch mode: `bun run compile:watch`
- Clean build artifacts: `bun run clean`

