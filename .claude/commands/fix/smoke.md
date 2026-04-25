Smoke tests are currently failing. Identify and fix the failures.

**Step 1: Run smoke tests to see what's failing**

Run `bun run test:cli` from the repo root and capture the output.

**Step 2: Analyse failures**

For each failing test:
- Identify whether the test itself is wrong or the implementation is wrong.
- Prefer fixing the implementation unless the test is clearly testing the wrong thing.

**Step 3: Fix**

Work through each failure and fix it. Mark each done as you go with TodoWrite.

**Step 4: Verify**

Re-run `bun run test:cli` to confirm all smoke tests pass. If new failures appear, fix those too and repeat until clean.

**Step 5: Summarise**

Report what was fixed and why.
