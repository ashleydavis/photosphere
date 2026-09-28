# ts-verify-timing.sh

Timing helpers for the TypeScript `psi verify` calls the Zig smoke suites make.

Every Zig suite runs the TypeScript CLI's `psi verify` on each database the Zig CLI creates or
modifies, so the reference implementation checks the integrity of what the Zig port writes. Those
calls are TypeScript work inside a Zig suite, so their time is recorded separately. That lets the Zig
suites be compared with the TypeScript suites with the verify cost taken out.

## Use

It is sourced, never run:

```bash
source "<apps/cli>/smoke-tests-zig/lib/ts-verify-timing.sh"
```

It is sourced by `smoke-tests-zig/lib/common.sh` (for the `ts_verify` helper the tests call), by the
`smoke-tests-zig.sh` runner (to total the time the tests report), and by the other Zig suites:
`smoke-tests-encrypted-zig.sh`, `sync-smoke-test-zig.sh` and `write-lock-smoke-test-zig.sh`.

## Functions

- `current_milliseconds`: prints the current time in milliseconds. Uses `EPOCHREALTIME` where bash
  has it and whole seconds from `date` where it does not (the bash 3.2 macOS ships).
- `record_ts_verify_milliseconds <log file> <start milliseconds>`: appends the milliseconds since
  `<start milliseconds>` to `<log file>`, one line per verify call.
- `sum_ts_verify_milliseconds <log file>...`: prints the total of every log given. A log that does
  not exist counts as zero.
- `count_ts_verify_calls <log file>...`: prints how many verify calls the logs given record.
- `format_milliseconds_as_seconds <milliseconds>`: prints the value as seconds with one decimal.

Each test of the main Zig suite writes its log to `ts-verify-milliseconds.log` in its own temporary
directory. The recorded timings are in [docs/zig-smoke-timings.md](../../../../docs/zig-smoke-timings.md).
