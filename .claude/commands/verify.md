Run all four quality checks for this project in sequence and report results:

1. `bun run compile` — TypeScript compile check
2. `bun run test` — unit tests
3. `bun run test:cli` — smoke tests

Run each command with the Bash tool. After all checks complete, print a summary table showing pass or fail for each check. If any check failed, include the relevant error output so the user knows what needs fixing.

If any of the checks fail, stop and report to the user. Do not continue running.

Report only, do not attempt to fix failures.