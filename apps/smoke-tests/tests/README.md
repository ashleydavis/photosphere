# Mobile smoke tests

Each test lives at `<n>-<name>/test.sh` and is platform-neutral: the same file runs against Android and iOS. See [docs/testing/README.md](../../../docs/testing/README.md) for how to run them.

## Scheduling markers

`bun run test:and` spreads the tests over every ready emulator, one worker per device. Two optional marker files in a test's own directory control how it is scheduled. Both are empty files; only their presence matters.

### `.exclusive`

Only one `.exclusive` test runs at a time across the whole pool, however many workers there are.

This exists for the LAN-share tests. Device discovery is a UDP broadcast to `255.255.255.255:54321` on the `192.168.55.0/24` segment that every emulator shares with the host, so two of these running at once see each other's traffic. `37-lan-share-timeout` asserts that *no* receiver is found, so a concurrent `26-receive-database` would make it fail. The tests currently marked are `7-share-secret`, `8-share-database`, `9-share-roundtrip`, `26-receive-database`, `27-receive-secret` and `37-lan-share-timeout`.

Mark any new test that puts a LAN-share sender or receiver on the network.

### `.slow`

A `.slow` test is moved to the front of the queue, so it starts on a worker immediately instead of being the last thing still running while every other worker sits idle.

Only `37-lan-share-timeout` is marked. It waits out a real 60 second LAN-share window, which makes it several times longer than any other test.
