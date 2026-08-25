# Open the default database when automatic import creates it

## Overview

Switching automatic import on creates the default "My Photos" database, and nothing opens it. Photos start arriving and the gallery goes on showing nothing, with nothing telling the user there is a database to open. It should be opened for them, and recorded as the last database so it is open again next time the app starts.

**The approach is deliberately not decided here. Decide it, with the human, before starting this plan.** The steps below are what has to be true when it is done, not how to do it.

## Issues

- [ ] The approach has not been chosen. Agree it with the human before writing any code.

## Steps

1. **Agree the approach with the human first.** Where the open is triggered from, and how the code learns the database exists, are both open questions. Do not choose either alone. Three previous attempts were written and rejected for being larger than the problem.

2. **Make the default database open when automatic import creates it**, on every platform, from one place rather than one per platform.

3. **Make sure opening it records it as the last database.** The shared open path already does this; the requirement is that this route goes through it rather than around it.

4. **Cover it with an end-to-end test.** The behaviour lives in a React component or context, which this repository does not unit test, so a smoke test is the only thing that can prove it.

Each step is finished only when the code compiles and the tests pass.

## Unit Tests

To be decided with the approach. Any plain function the approach introduces gets one; React components, contexts and hooks do not get unit tests and are covered below instead.

## Smoke Tests

Extend `apps/smoke-tests/tests/47-auto-import/test.sh`, which already switches automatic import on and waits for the first photo. It should assert the database is open without the test opening it.

Watch the assertion fail before accepting it: the test passed before this feature existed, so an assertion that does not fail without the fix proves nothing.

## Verify

- `mise exec -- bun run compile` is clean.
- `mise exec -- bun run test` passes.
- `mise exec -- bun run test:everything -- --force` passes.
- Test 47 passes with the change and fails without it.

## Notes

**Facts that constrain the approach, established by reading the code:**

- The database does not exist at the moment the toggle goes on. The platform creates it afterwards: the Electron main process on the desktop, a background import pass on a phone. Anything that reads the default database path once, at toggle time, finds nothing.
- Both platforms record the path in config once the database exists (`defaultDatabasePath`), so that value becoming set is one signal that it is ready. It is not the only possible signal.
- A database the user already has open must be left alone. Taking them out of what they are looking at is worse than not opening anything.

**Already tried and rejected, so a later attempt does not repeat them:**

- A new platform-event variant fired by each platform, with the shared interface acting on it. Rejected as too large: it touched the event union, every platform provider, and the Electron main process.
- Polling for the default database path from the settings card, with the waiting extracted to a testable function. Rejected: the extracted file was not wanted.
- The same polling inlined in the settings card. Rejected.

None of these were rejected on grounds of not working. The objection each time was size and placement, which is why the approach is the first thing to settle.
