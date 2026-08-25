# The photo count should update live while photos are being imported

## Overview

While automatic import is running, the number of photos the interface shows falls behind what the database holds and never catches up. The user watches a count that is wrong and has no way to know it, which on a first backup of a whole library is hours of not knowing whether anything is working.

**How to do this is not decided here.** The first part of the work is agreeing the approach with the human. Three attempts at neighbouring problems were written and rejected today for being larger than the problem, so the shape is settled first and written second.

## Issues

- [ ] The approach has not been agreed with the human. Do that before writing any code.

## Steps

1. **Agree the approach with the human before anything else.** Bring them the measurements below, propose the smallest thing that could work, and get it agreed. Do not start on the rest of the plan until they have said what shape they want.

2. **Make the count the user is looking at follow what has actually been imported**, while the app is on screen, without them navigating, reopening a database, or leaving the app and coming back.

3. **Cover it with an end-to-end test.** The count lives in a React component, which this repository does not unit test, so a smoke test is the only thing that can prove it.

Each step is finished only when the code compiles and the tests pass.

## Unit Tests

To be decided with the approach. Any plain function it introduces gets one; React components, contexts and hooks do not, and are covered below instead.

## Smoke Tests

Extend `apps/smoke-tests/tests/47-auto-import/test.sh`, which already switches automatic import on and imports photos with the app running.

Two things to know about testing this, both learned the hard way:

- **Do not navigate before asserting the count.** Navigating to the gallery rebuilds it from the database, so it reports the right number whether or not anything reached it live. The existing assertion does this and would pass with the feature completely broken.
- **Nothing about the gallery is observable from outside.** It has no `data-id` carrying a count and its "Gallery loaded" line only fires on load, not on arrival. Something has to make the count readable before it can be asserted on.

Watch the assertion fail before accepting it.

## Verify

- `mise exec -- bun run compile` is clean.
- `mise exec -- bun run test` passes.
- `mise exec -- bun run test:everything -- --force` passes.
- Test 47 passes with the change and fails without it.

## Notes

**Measured on a real device, and worth trusting over any theory:**

- Photos imported **while the app is on screen do reach the gallery live**. A smoke test was written for exactly this case, with a photo seeded while the gallery was displayed and no navigation afterwards, and it passed. The live path works.
- Photos imported **while the app is off screen are lost to the interface**. They are announced once, to a WebView that is not running, and never announced again.
- The loss is **one-time, not ongoing**. Two readings seventeen minutes apart: the interface showed 209 against 217 on disk, then 222 against 230. A gap of exactly 8 both times. The count tracks every photo since; it is permanently short by the ones that arrived while nobody was listening.

So the problem to solve is recovering what was missed, not fixing a broken message path.

**Already tried and rejected today, so a later attempt does not repeat them:**

- Reloading the open database when the app returns to the foreground. This is committed and works, but it only helps if the user thinks to leave the app and come back.
- Reloading when an import pass finishes. Rejected. It also does nothing during a first backup, where a single pass runs for hours.

**Two things that will bite whoever picks this up:**

- A first pass over a large library is one task that runs for hours, so anything keyed to a pass ending will not fire during exactly the period the user is watching.
- The app's own log is only readable through the smoke-test control bridge. On a device being used normally there is no way to see what the interface thinks, which is why the diagnosis above came from counting files on disk instead.
