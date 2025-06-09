# cli

The Photosphere CLI tool.

To install dependencies:

```bash
cd apps/cli
bun install
```

## Building the frontend

The CLI tool embeds the frontend UI, when testing locally, you need to build that first.

Run one of the following:

```bash
bun run build-fe-linux
bun run build-fe-win
bun run build-fe-mac
```

## Testing the CLI tool locally

```bash
bun run start -- <command> [db-path]
bun run start:dev -- <command> [db-path]
```

Example commands for testing are encoded in this script:

```bash
bun run create-simple-database-test
```

Use Git diff (or similar) to determine if the test worked.

## Building the CLI tool with embedded frontend

You need zip installed to zip the frontend package:

```bash
apt update 
apt install zip
```

First build the frontend:

```bash
cd frontend
bun run build-cli
```

Build the CLI tool:

```bash
cd apps/cli
bun run build-linux
bun run build-win
bun run build-mac
```

The executable is built to:

```bash
bin/linux/psi
bin/win/psi.exe
bin/mac/psi
```

## Running on macOS

If you encounter "cannot be opened because the developer cannot be verified" when running the macOS binary, remove the quarantine attributes:

```bash
xattr -c ./psi
```

This removes the quarantine attributes that macOS Gatekeeper adds to downloaded or built unsigned binaries.


