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

## Scheduling

`bun run test:and` spreads the tests over every ready emulator, one worker per device, dispatching them in the order they are numbered. There are no scheduling markers: nothing reorders the tests and nothing serialises them, so any test may run beside any other.

That includes the LAN-share tests, which used to be serialised by a `.exclusive` marker. Device discovery is a UDP broadcast to `255.255.255.255:54321` on the `192.168.55.0/24` segment that every emulator shares with the host, so every share on the machine is heard by every other. What keeps them apart is the pairing code, not the scheduling: a sender ignores any receiver whose code hash is not its own (`packages/lan-share-network/src/lib/lan-share-sender.ts`), a receiver rejects a payload carrying the wrong code, and each test draws a random code rather than hardcoding one.

A new LAN-share test therefore needs no marker. It does need to draw its pairing code rather than hardcode it, which is what makes it safe beside another copy of itself.
