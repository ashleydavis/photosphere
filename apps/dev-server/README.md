# Dev-server

A development server with for the Dev-frontend that's faster than developing directly with Electron.

## Project Structure

```
dev-server/
├── src/
│   ├── index.ts                              # Server entry point
│   └── lib/
│       ├── task-queue-provider-inline.ts     # Inline task queue provider
│       └── worker-pool-inline.ts          # Inline worker pool
├── package.json
└── tsconfig.json
```

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

