# udp-listen.ts

Listens for a LAN share receiver's UDP discovery broadcast on port 54321, prints the first one carrying the expected pairing code hash (`PSIE_RECV:{port}:{codeHash}:{fingerprint}`) and exits. The LAN share smoke tests start it through `capture_receiver_broadcast` in `lan-share.sh`; it is not run by hand.

```
bun run apps/cli-zig/smoke-tests/lib/udp-listen.ts <expected-code-hash>
```

- `<expected-code-hash>`: the SHA-256 of the pairing code the receiver was started with. Required, so a broadcast from another run's receiver on the same network is ignored.
