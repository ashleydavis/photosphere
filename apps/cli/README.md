# cli

The Photosphere CLI tool.

To install dependencies:

```bash
bun install
```

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

Then build the CLI tool (which embeds the frontend):

```bash
cd apps/cli
bun run build-exe-linux
bun run build-exe-win
bun run build-exe-mac
```

The executable is built to:

```bash
bin/linux/psi
bin/win/psi.exe
bin/mac/psi
```


