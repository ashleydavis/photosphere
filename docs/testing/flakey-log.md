# Flakey log

A dated record of each time the suites were hardened with `bun run test:parallel` and `bun run find-flakey-tests`: what ran, what failed, and what was done about it. Failure modes themselves are described in [the flaky-test failure registry](../flaky-tests-registry.md); this is just the history.

Always record the ladder target, because that is what a green result is worth.

## 2026-08-23

Ladder target: 10 green runs a rung.

- `test:parallel`: green. Every suite clean alone, and every pairing of two clean together. `tmp/parallel-check/20260823-181014`
- `find-flakey-tests --ladder`: green. `test`, `test:cli`, `test:electron` and `test:and` each made 10 green runs first time. `tmp/find-flakey-tests/20260823-184115`
- Failures: none. Nothing changed, nothing committed.
- `test:ios` is not in the set on Linux, so pairings involving it went unchecked.

## 2026-08-24

Ladder target: 10 green runs a rung.

- `test:parallel`: green after one fix. Every suite clean alone, and all 66 pairings clean. `tmp/parallel-check/20260824-135557`
- `find-flakey-tests --ladder`: green. Every rung made its 10 green runs first time, 1h 50m for the climb. `tmp/find-flakey-tests/20260824-194904`
- What failed: the first `test:parallel` attempt (`tmp/parallel-check/20260824-085103`) found `test:electron` unstable on its own, test 26 (s3-database-lifecycle). Reopening the database the app had already restored at startup cancelled the load that was running for it. Fixed in 8ffb301c; see S3-LIFECYCLE-GALLERY-EMPTY-AFTER-LOAD in [the registry](../flaky-tests-registry.md), which turned out to be the same cause and had been open since 2026-08-14.
- Also fixed: `find-flakey-tests --test` handed its filter to `what-changed baseline capture` rather than the suite runner, so a filtered loop ran the whole suite and then reported a red run in which nothing had failed. 2b202f67.
- Earlier attempts on the same day stopped on the emulator pool losing a device mid-run rather than on a test, which is why there are three earlier `tmp/parallel-check` directories.
- `test:ios` is not in the set on Linux, so the 12 combinations involving it went unchecked.
