# Dev Server

A development server with WebSocket support for the Photosphere frontend.

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
bun run start:dev
```

### WebSocket Connection

The server listens for WebSocket connections on `ws://localhost:3001`.

When a client connects:
1. The server logs "WebSocket connection opened"
2. The client sends "hello-server"
3. The server receives and logs the message
4. The server responds with "hello-frontend"
5. The client receives and logs the message

All messages are logged to the console on both client and server.

## Development

- Compile TypeScript: `bun run compile`
- Watch mode: `bun run compile:watch`
- Clean build artifacts: `bun run clean`

