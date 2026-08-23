# Flakey log

A dated record of each time the suites were hardened with `bun run test:parallel` and `bun run find-flakey-tests`: what ran, what failed, and what was done about it. Failure modes themselves are described in [the flaky-test failure registry](../flaky-tests-registry.md); this is just the history.

Always record the ladder target, because that is what a green result is worth.

## 2026-08-23

Ladder target: 10 green runs a rung.

- `test:parallel`: green. Every suite clean alone, and every pairing of two clean together. `tmp/parallel-check/20260823-181014`
- `find-flakey-tests --ladder`: green. `test`, `test:cli`, `test:electron` and `test:and` each made 10 green runs first time. `tmp/find-flakey-tests/20260823-184115`
- Failures: none. Nothing changed, nothing committed.
- `test:ios` is not in the set on Linux, so pairings involving it went unchecked.
