# Zig smoke suite timings

How long each Zig CLI smoke suite takes beside its TypeScript twin, measured on the shared 4-core Linux
development machine with `time bun run <script>`, one suite at a time.

The Zig suites run the TypeScript CLI's `psi verify` after every step in which the Zig CLI creates or
modifies a database, so the reference implementation checks everything the Zig port writes. Those
calls are TypeScript work inside a Zig suite, so every Zig suite measures them and prints the total
(`TypeScript verify: <calls> calls, <seconds>`), and the main suite prints each test's share on its
result line. The comparison below takes them out.

## How to read the numbers

The machine is shared with other worktrees' test runs, and its load average moved between 2 and 40
during these measurements. Wall-clock time follows the load, so each run is given with the load
average at its start, and the two measures that the load moves least are given as well:

- **CPU time** (`user` + `sys` from `time`). A TypeScript `psi verify` of a small database costs about
  2.1 s of CPU (measured over five calls: 1.9 s wall, 1.4 to 1.8 s user and 0.35 to 0.44 s sys), so a
  Zig suite's CPU time without its verify calls is its CPU time less 2.1 s per call.
- **Test-seconds** (main suite only). The main suites run their tests four at a time, so a verify
  call's wall time cannot simply be subtracted from the suite's wall time. The sum of the tests' own
  durations can have it subtracted exactly, because each test records its verify time.

The main Zig suite has twelve tests the TypeScript suite does not (90 to 101: hash, check, tools,
examples, help, news, bug, debug, hash-cache, remove-orphans, origin, mcp). Its test-second totals are
also given for tests 1 to 89 alone, which are the TypeScript suite's tests.

## Before: the suites as they were (commit f91bc16)

Each Zig suite then made one TypeScript verify at the end of most tests.

| Suite pair | TypeScript | Zig | Load at start (TS / Zig) |
|---|---|---|---|
| main (`test:cli`, `test:cli:zig`) | 7m 46s (CPU 19m 07s; 2 failures, 78 and 79) | 12m 40s (CPU 16m 19s) | ~4 / ~12 to 18 |
| encrypted | 4m 38s | 3m 56s | 3.9 / 18.2 |
| sync | 7m 02s | 3m 10s | 17.3 / 27.9 |
| write-lock | 2m 09s | 0m 44s | 21.3 / 18.7 |
| hash-cache | 1m 06s | 0m 04s | 17.4 / 21.4 |
| LAN share | 1m 22s | 1m 25s | 21.4 / 6.7 |

In the Zig main run, test 75 (the Zig CloudStorage integration suite against MinIO) took 407 s, almost
all of it compiling the suite and the AWS SDK for C into a Zig cache that did not have them yet. Four
cores spent compiling slowed every test running beside it. On a warm cache (CI builds it in the unit
test step just before) the same test takes 13 s.

## After: a TypeScript verify after every write

| Suite pair | TypeScript | Zig | Zig TypeScript verify | Zig without the verify calls | Load at start (TS / Zig) |
|---|---|---|---|---|---|
| main, warm cache | 8m 21s, CPU 18m 06s | 9m 00s | 305 calls, 1180 s of 2475 test-seconds | tests 1 to 89: 1072 test-seconds against the TypeScript suite's 2282 | ~3 / 3.1 |
| main, after dropping repeated verifies | 8m 50s, CPU 18m 25s | 17m 59s, CPU 19m 21s | 238 calls, 1981 s of 4881 test-seconds | CPU about 11m 02s (19m 21s less 238 x 2.1 s) against 18m 25s | 0.2 / 10 rising to 40 |
| encrypted | 4m 04s | 4m 06s | 76 calls, 167 s | 1m 59s | 16.8 / 9.8 |
| encrypted, after dropping repeated verifies | 3m 46s | 3m 08s | 54 calls, 110 s | 1m 58s | 40.2 / 8.1 |
| sync | 2m 08s (CPU 6m 20s) | 1m 12s (CPU 2m 52s) | 13 calls, 24 s | 0m 47s | 4.2 / 6.1 |
| write-lock | 1m 10s (CPU 2m 13s) | 0m 31s (CPU 0m 40s) | 2 calls, 4 s | 0m 27s | 4.4 / 2.6 |
| hash-cache | 0m 29s (CPU 1m 42s) | 0m 03s (CPU 0m 05s) | none (no database) | 0m 03s | 2.0 / 9.1 |
| LAN share | 1m 20s | 1m 24s | none (no database) | 1m 12s without the four interop tests | 3.1 / 2.0 |

The sync, write-lock, encrypted and LAN suites run one test at a time, so their verify time comes off
their wall time directly.

### Main suite

With the machine quiet (load about 3 for both), the Zig suite's tests 1 to 89 took 2113 test-seconds,
1041 of them in TypeScript verify calls, which leaves 1072 against the TypeScript suite's 2282: the
Zig CLI does the same tests' own work in less than half the time. The whole suite, all 101 tests with
every verify, took 9m 00s of wall time against the TypeScript suite's 8m 21s.

The later run, after dropping repeated verifies, had another worktree's runs push the load from 10 to
40 while it ran, so its wall time says little. Its CPU time does: 19m 21s, of which about 8m 20s went
on its 238 TypeScript verify calls, leaving about 11m for 101 tests against 18m 25s for the TypeScript
suite's 89.

Each Zig CLI command takes about a third of the wall time and a sixth of the CPU of its TypeScript
equivalent (a `psi verify` of the same
database: 0.2 to 0.3 s of user CPU against 1.4 to 1.8 s), so there was no slow Zig code to fix. What
made the Zig suite slow was the TypeScript verify calls themselves, and the fix was to stop repeating
them: a verify at the end of a test that checks a database nothing has written since its last verify
is the same check twice, so those were removed (305 calls down to 238), and `invoke_command` no longer
runs `root-hash` after a TypeScript verify.

### LAN share

Both LAN suites spend 61 s of their 80 s in one test, "Wrong pairing code is rejected", where the
sender waits out the 60 s discovery timeout that both CLIs use. The Zig suite runs the TypeScript
suite's seven tests (73 s against 80 s) and then four interop tests that put the TypeScript CLI on one
side of a share (11 s), which are to this suite what the verify calls are to the others.

## CI

The Release workflow gives the main Zig smoke step 14 minutes. Before the verify calls were added the
step took 2m 56s on ubuntu-latest. With a verify after every write (commit 0a77149, before repeated
verifies were dropped) it took 5m 27s on ubuntu-latest, 4m 17s on macos-latest and 10m 49s on
windows-latest, where a TypeScript verify costs about 3.5 s (301 calls, 1054 s of 2879 test-seconds).
Dropping the repeated verifies takes 63 of those calls away.
