# Notes

Notes taken during work, each one waiting to be categorised.

## Notes

- When entering the destination in the replicate diaglog, there should be some kind of browser. Also it should default the destination name to the name of the remote database, unless that already exists locally.
- There needs to be a popup before triggering any permissions prompts to explain to the user why those are required.
- Automatic import needs to work on all platforms.
- Automatic import and syncing on every platform (desktop and mobile) must behave as the manual tests describe: the onboarding tests (`docs/testing/e2e/onboarding/`) and every other manual test that covers automatic import or syncing (`docs/testing/e2e/mobile/auto-import/` and the like). The work that brings them to desktop must add comprehensive unit tests and smoke tests for that behaviour.
