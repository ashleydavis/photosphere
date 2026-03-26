# cli

The Photosphere CLI tool.

## Project Structure

```
cli/
├── index.ts                              # Entry point
├── worker.ts                             # Worker process for task execution
├── src/
│   ├── cmd/                              # CLI commands
│   ├── lib/                              # Shared libraries
│   └── test/                             # Unit tests
├── smoke-tests.sh                        # Comprehensive smoke tests
├── smoke-tests-encrypted.sh              # Encrypted database smoke tests
├── package.json
└── tsconfig.json
```

## Setup

To install dependencies, run from the root of the monorepo:

```bash
bun install
```

## Testing the CLI tool locally

```bash
bun run start -- <command> [options]
bun run dev -- <command> [options]
```

## Building the CLI tool

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

## Encrypted database smoke tests

Encrypted database workflows (init with encryption, replicate to/from encrypted databases, encrypt/decrypt, and basic CRUD on encrypted data) are covered by a dedicated script: `smoke-tests-encrypted.sh`.

```bash
# Run all encrypted smoke tests (from code)
./smoke-tests-encrypted.sh all

# Use built binary instead of bun run start --
./smoke-tests-encrypted.sh --binary all

# Run a single encrypted test
./smoke-tests-encrypted.sh encrypt-plain

# Override the temporary directory (useful for parallel runs)
TEST_TMP_DIR=./test/tmp-enc ./smoke-tests-encrypted.sh all
```

