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
bun run start -- <command> [options]
bun run start:dev -- <command> [options]
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

## Running Smoke Tests

The CLI includes comprehensive smoke tests that verify all major functionality. The tests are located in `smoke-tests.sh`.

### Prerequisites

The smoke tests require the following tools to be installed:
- ImageMagick (for image validation)
- ffmpeg and ffprobe (for video validation)

### Running Tests

```bash
# Run all tests (assumes CLI executable is already built)
./smoke-tests.sh all

# Build the CLI and run all tests
./smoke-tests.sh setup,all

# Build, check tools are installed, and run all tests
./smoke-tests.sh setup,check-tools,all

# Run specific tests by number (e.g., tests 1-5)
./smoke-tests.sh to 5

# Run in debug mode (uses 'bun run start --' instead of built executable)
./smoke-tests.sh --debug all
./smoke-tests.sh -d to 10

# Run individual tests
./smoke-tests.sh create-database  # Test 1: Create database
./smoke-tests.sh add-png          # Test 3: Add PNG file
./smoke-tests.sh verify           # Test 10: Verify database

# Clean up test artifacts
./smoke-tests.sh reset

# Check if required tools are installed
./smoke-tests.sh check-tools
```

