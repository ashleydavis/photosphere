# Step 2: Inventory the Node/Bun API surface and create the host-bridge checklist

Produce the complete inventory of Node/Bun runtime APIs used by the worker code and its dependency packages, and turn it into the source-of-truth checklist file. This step produces a checked-in markdown file as its output (the inventory itself).

## What to do

1. Bundle the worker entry path with `bun build --target=browser` to surface unresolved Node built-ins as build errors (this is one input to the inventory).
2. As the authoritative backstop, grep the worker code and its dependency packages (`storage`, `node-api`, `merkle-tree`, `utils`, and any others the handlers import) for: `node:`, `fs`, `fs/promises`, `path`, `crypto`, `os`, `stream`, `child_process`, `worker_threads`, `Buffer`, `process`, and the network APIs `http`, `https`, `net`, `tls`, `dns`, `fetch`.
3. For each API found, decide and record one resolution:
   - Pure-JS shim bundled into `worker.bundle.js` (e.g. `path`, small `Buffer`/`Uint8Array` helpers, a JS `stream` shim), or
   - A native host function on the `host` bridge implemented in Swift (iOS) and Java (Android) (e.g. storage IO, `host.sha256`, media tools).
4. Explicitly confirm the network APIs: once storage is `HostStorage`, no bundled handler should need `http`/`https`/`net`/`tls`/`dns`/`fetch`. If the grep finds any, record whether it is routed through a dedicated host function or the handler is excluded from the mobile bundle. The build must not silently pull a network stack into the engine.

## Output file

Create `docs/mobile-host-bridge-checklist.md`: a markdown table mapping every API / host function to its resolution and a per-platform status (`not-started` / `stubbed` / `implemented` / `tested`) for iOS and Android separately. This file is the source of truth for remaining native work and is updated by later steps.

## Tests

No code change here beyond the checklist document, so no unit/smoke tests are required for this step. If the bundling probe is captured as a repeatable script, add it as a documented `bun run` script rather than an ad-hoc command.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
