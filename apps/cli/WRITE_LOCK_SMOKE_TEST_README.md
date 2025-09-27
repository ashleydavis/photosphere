# Write Lock Smoke Test

This document describes how to use the write lock smoke test script to verify database integrity under concurrent access.

## Overview

The `write-lock-smoke-test.sh` script tests the write lock functionality of the Photosphere CLI by running multiple parallel processes that simultaneously add PNG files to the same database. This ensures the database remains uncorrupted and all files are properly tracked when multiple processes attempt to write concurrently.

## Prerequisites

- **ImageMagick**: Required for PNG generation (`convert` command)
- **sha256sum**: Required for file hash calculation
- **Photosphere CLI**: Either built binaries or development environment with Bun

## Usage

```bash
./write-lock-smoke-test.sh [OPTIONS]
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--debug` | false | Use `bun run start` instead of compiled binaries |
| `--processes N` | 4 | Number of parallel processes to run |
| `--iterations N` | 6 | Number of file additions per process |
| `--sleep-range MIN-MAX` | 0.1-2.0 | Sleep range in seconds between file additions |
| `--help` | - | Display help message |

### Examples

#### Basic Test (Default Settings)
```bash
./write-lock-smoke-test.sh
```
- Runs 4 parallel processes
- Each process adds 6 files
- Random sleep between 0.1-2.0 seconds

#### Development Mode
```bash
./write-lock-smoke-test.sh --debug
```
Uses `bun run start` instead of compiled binaries, useful during development.

#### Stress Test
```bash
./write-lock-smoke-test.sh --processes 10 --iterations 10
```
Runs 10 parallel processes, each adding 10 files (100 total files).

#### Fast Test
```bash
./write-lock-smoke-test.sh --processes 2 --iterations 3 --sleep-range 0.1-0.5
```
Quick test with minimal delays for rapid feedback.

#### Slow Test (High Contention)
```bash
./write-lock-smoke-test.sh --processes 8 --iterations 5 --sleep-range 2.0-5.0
```
Tests with longer delays to create different timing patterns.

## What the Test Does

1. **Environment Setup**
   - Creates temporary directories for database, files, and process outputs
   - Initializes a fresh Photosphere database

2. **Parallel Execution**
   - Spawns the specified number of worker processes
   - Each process generates unique PNG files with random colors/dimensions
   - Processes sleep for random intervals within the specified range
   - Files are added to the shared database using the CLI

3. **File Tracking**
   - Each process logs: timestamp, filename, hash, size, and add result
   - Output files stored in `./test/tmp/write-lock-outputs/process_N.log`

4. **Validation**
   - Verifies database integrity using `psi verify`
   - Confirms all tracked files exist with correct metadata
   - Validates that all successfully added files are in the database

## Output Files

When running in debug mode (`--debug`), temporary files are preserved:

- `./test/tmp/write-lock-test-db/` - Test database
- `./test/tmp/write-lock-files/` - Generated PNG files
- `./test/tmp/write-lock-outputs/` - Process log files

### Process Log Format
```
# Process 1 output
# Format: timestamp,filename,hash,size_bytes,add_result
1758939000188008219,process_1_iter_1_1758939000188008219.png,5ee038692d0455ea349cea8ed68db4754337b5775b83d56e696e48e87a6a8aa0,180,SUCCESS
```

## Exit Codes

- `0` - All tests passed
- `1` - Test failure (database corruption, missing files, etc.)

## Troubleshooting

### Missing Dependencies
```bash
# Install ImageMagick on Ubuntu/Debian
sudo apt-get install imagemagick

# Install ImageMagick on macOS
brew install imagemagick
```

### CLI Binary Not Found
If running without `--debug` and binaries aren't built:
```bash
# Build binaries first
bun run build-linux   # or build-mac, build-win
```

### Database Integrity Failures
If the test reports database corruption:
1. Check for sufficient disk space
2. Verify no other processes are accessing the test database
3. Run with `--debug` to see detailed error messages
4. Try with fewer processes (`--processes 2`)

## Performance Tuning

### For Maximum Stress Testing
- Increase processes: `--processes 16`
- Increase iterations: `--iterations 20`
- Use tight timing: `--sleep-range 0.05-0.2`

### For Debugging
- Use minimal load: `--processes 1 --iterations 2`
- Use debug mode: `--debug`
- Increase delays: `--sleep-range 5.0-10.0`

## Expected Results

A successful test run should show:
```
[PASS] Database integrity check passed
[PASS] All file verification checks passed
[PASS] Write lock smoke test PASSED
```

The test validates that:
- No database corruption occurs under concurrent access
- All files are properly added and tracked
- File metadata (hash, size) remains consistent
- The write lock mechanism prevents data races