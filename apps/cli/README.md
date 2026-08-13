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

# Run against the TypeScript sources instead of the built executables
./smoke-tests.sh --source

# Run individual tests
./smoke-tests.sh create-database  # Test 1: Create database
./smoke-tests.sh add-png          # Test 3: Add PNG file
./smoke-tests.sh verify           # Test 10: Verify database

# Clean up test artifacts
./smoke-tests.sh reset

# Check if required tools are installed
./smoke-tests.sh check-tools
```

### How a full run is scheduled

A full run keeps several tests going at once in a rolling pool: as soon as one test finishes its slot is refilled, so no lane sits idle waiting for a slower test beside it. The pool itself is `scripts/lib/test-pool.sh`, shared with the desktop suite.

- **How many at once.** Taken from the core count (a quarter of it, capped at 6). `--parallel N` sets it explicitly and beats everything else. `PHOTOSPHERE_TEST_PARALLEL` sets it for a caller that is running other suites beside this one, which is how `scripts/test-everything-parallel.sh` hands each lane a share of the machine; a value that is not a positive integer is refused rather than guessed at. The run prints the width it chose.
- **The five-file database is built once.** 18 tests need a database holding the five standard test files, and each used to build its own at about 5 seconds a time. The run now builds one before the tests start and each test copies it, through `create_db_with_5_files` in `smoke-tests/lib/common.sh`. The copy includes the UUID counter, without which a test that adds an asset after copying would mint a UUID the copied database already holds. A test run on its own from the command line has no fixture and builds the database itself, and so does the S3 test whose database lives in a bucket rather than in a directory.
- **The tests run against the compiled binaries.** A full run builds `psi`, `mk` and `bdb` first and runs everything against them, which is both what ships and about 0.10s an invocation cheaper than going through `bun run start`. `--source` runs against the TypeScript instead.

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

