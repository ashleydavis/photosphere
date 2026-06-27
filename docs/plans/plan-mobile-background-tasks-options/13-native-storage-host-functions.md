# Step 13: Implement the native storage host functions (both platforms)

Implement the real storage host functions backing `HostStorage`, against the storage backend chosen in `plan-mobile-storage-options.md`.

## What to do

1. Implement `host.storageRead`, `host.storageWrite`, `host.storageList`, `host.storageDelete`, `host.storageStat` in Swift (iOS) and Java (Android) against the chosen storage backend.
2. Implement `host.sha256(path)` natively (path-based hashing, never whole-file base64) and the large-blob path-to-path / streamed host calls used by `HostStorage` (`host.storageCopy` / streamed read-to-file).
3. Every path-taking function goes through the shared path-sandbox guard (Step 5); the sandbox root is the storage backend's root.
4. All host functions must be thread-safe, since they are called concurrently from multiple engine threads.
5. Update `docs/mobile-host-bridge-checklist.md` to `implemented` / `tested` for each storage function as it lands.

## Tests

- iOS (XCTest) and Android (JUnit / Robolectric or instrumented) host-function tests, one per implemented storage function: storage read/write/list/stat/delete against a temp directory, `sha256` against a known vector, and the large-blob path-to-path copy.
- Confirm the path-sandbox guard (Step 5) applies to each of these functions (traversal vectors rejected, in-root paths accepted).

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
