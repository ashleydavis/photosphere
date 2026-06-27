# Step 4: Implement `HostStorage`, the storage import alias, and the byte-payload split

Make the bundle self-contained and engine-runnable by replacing Node-only dependencies with shims or host calls, centred on storage.

## What to do

1. Implement `HostStorage` (a mobile `IStorage`) that implements every `IStorage` method by calling host bridge functions (`host.storageRead`, `host.storageWrite`, `host.storageList`, `host.storageDelete`, `host.storageStat`).
2. Add the `bun build` alias (a Bun build plugin or a `bunfig.toml` alias) so handler imports of the storage package resolve to `HostStorage` in the mobile bundle, and drop the worker-pool layer (`worker_threads` / `child_process`) from the bundle.
3. Add the `Buffer` / `crypto` resolutions per the inventory (Step 2): rely on Bun's browser-target `Buffer` polyfill or refactor touched code to `Uint8Array`; provide a JS `crypto`/hashing implementation or route to `host.sha256` per hot path (large-file hashing goes native).
4. Implement the small-payload-base64 vs large-blob file-handle split in `HostStorage`:
   - Bytes cross the bridge as base64 only for small payloads; enforce a size threshold (for example 1 MB).
   - Above the threshold, bytes never cross as base64; use path-to-path / streamed host calls (`host.storageCopy` / streamed read-to-file) and path-based host functions (`host.sha256(path)`, media functions by path) so bytes stay native.

## Tests

- `HostStorage` test: assert each `IStorage` method calls the matching `host.storage*` function and marshals small byte payloads as base64 correctly, and that payloads over the threshold use the file-handle/path host call instead of base64.
- Large-payload round-trip test: write and read back a payload above the base64 threshold through `HostStorage`, assert the bytes are identical and that the base64 path was not used.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
