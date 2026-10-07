# Hash Cache Smoke Test (Zig)

`hash-cache-smoke-test-zig.sh` is the Zig counterpart of `hash-cache-smoke-test.sh`. It proves that separate OS processes can write the shared hash cache at the same time without losing entries or corrupting the file, with every psi command running in the Zig port of psi (`apps/cli-zig`).

## Prerequisites

- The Zig CLI, built with `zig build` in the repository root (the script fails at once if `../../zig-out/bin/psi` is missing).
- `bun install` from the repo root, for the TypeScript CLI in the interop check.
- `sha256sum`, which the TypeScript suite also uses.

## Usage

From the repo root:

```bash
bun run test:cli:hash-cache:zig
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--processes N` | 10 | Number of parallel writer processes |
| `--entries N` | 10 | Entries each process adds |
| `--help` | - | Display help message |

## Steps

The same steps as the TypeScript suite, in the same order, run through the Zig CLI:

1. Start the writer processes, each adding its entries with `psi hash-cache set`.
2. Check every writer exited cleanly and printed no warning or error under contention.
3. Check `psi hash-cache count` holds every entry and `psi hash-cache list` and `psi hash-cache get` read every entry back intact.
4. Remove one entry with `psi hash-cache remove` and check the count drops by one.

Then an interop check reads the cache the Zig writers produced with the TypeScript CLI: the entry count, the full `hash-cache list` output, one entry's hash and the absence of the removed entry must all match.

Everything the run writes lives in a temporary directory from `scripts/lib/test-lib.sh`, and every writer is recorded and stopped with `kill_process_tree`.

## CI

The Release workflow runs this suite on Linux, macOS and Windows in the `zig-smoke-tests` job, like the other Zig suites.
