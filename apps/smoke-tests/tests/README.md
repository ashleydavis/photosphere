# Mobile smoke tests

Each test lives at `<n>-<name>/test.sh` and is platform-neutral: the same file runs against Android and iOS. See [docs/testing/README.md](../../../docs/testing/README.md) for how to run them.

## Running one test

`bun run test:and` (or `test:ios`) takes an optional argument that narrows the run to a single test, so it can be iterated on without the full build-install-every-test cycle:

```bash
bun run test:and 26                     # by number
bun run test:and receive-database       # by part of the name
bun run test:and 26-receive-database    # by full directory name
```

An all-digits argument matches the number in front of the directory name exactly, so `2` runs `2-create-database` alone. Numbers are not unique (`9` and `17` are each used twice) and such a number selects both tests. Anything else is a case-insensitive substring of the directory name. An argument that matches no test is an error, reported before the build with the available test names listed.

## Scheduling markers

`bun run test:and` spreads the tests over every ready emulator, one worker per device. Two optional marker files in a test's own directory control how it is scheduled. Both are empty files; only their presence matters.

### `.exclusive`

Only one `.exclusive` test runs at a time across the whole pool, however many workers there are.

This exists for the LAN-share tests. Device discovery is a UDP broadcast to `255.255.255.255:54321` on the `192.168.55.0/24` segment that every emulator shares with the host, so two of these running at once see each other's traffic. `37-lan-share-timeout` asserts that *no* receiver is found, so a concurrent `26-receive-database` would make it fail. The tests currently marked are `7-share-secret`, `8-share-database`, `26-receive-database`, `27-receive-secret` and `37-lan-share-timeout`.

Mark any new test that puts a LAN-share sender or receiver on the network.

### `.slow`

A `.slow` test is moved to the front of the queue, so it starts on a worker immediately instead of being the last thing still running while every other worker sits idle.

Only `37-lan-share-timeout` is marked. It waits out a real 60 second LAN-share window, which makes it several times longer than any other test.
