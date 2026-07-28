# Remove the hand-written S3 client from the mobile worker

## Problem

`packages/mobile-worker/src/shims/aws-s3.ts` is 995 lines of hand-written S3: the wire protocol, XML parsing, and SigV4 request signing. It is aliased over `@aws-sdk/client-s3` at bundle time (`packages/mobile-worker/bundle.ts`) so the mobile background engine can reach S3.

It should not exist:

- Request signing and a storage protocol are not things to hand-write. There is no upstream fixing its bugs and no upstream security fixes.
- It sets a pattern that does not scale. Azure Storage, Google Cloud Storage and Dropbox would each need the same treatment: four protocol implementations, four signing schemes, all maintained here.
- The seam was put in the wrong place. It replaced the SDK. The right seam is `IStorage` in `packages/storage/src/lib/storage.ts`, which `FileStorage` already implements over host functions.
- Its own TLS decision (strip the scheme, always use validated TLS) is the sole reason the S3 smoke tests need a certificate authority, a TLS proxy and an Android trust anchor.

## The requirement this plan must satisfy

**A real, vendor-maintained SDK does the cloud work. Every step below is judged against this.**

- No hand-written wire protocol, XML/JSON response parsing, or request signing lives in this repository, for S3 or for any provider added later. Signing and protocol code is security-critical and gets upstream fixes only if it comes from upstream.
- This repository cannot afford to maintain a copy of the AWS SDK, and the same goes for Azure Storage, Google Cloud Storage and Dropbox. A solution that works for S3 but would need the same treatment again for the next provider has not solved the problem.
- Reaching the outcome by any other route (a "small" client, a trimmed fork, a vendored copy, a wrapper that still signs requests) is a failure of this plan, not a shortcut through it. If no real SDK can be made to work, stop and report that rather than writing one.

Two routes satisfy this, and step 2 decides which. Step 2's outcome A uses the real JavaScript AWS SDK inside the engine and is the better one, because a single SDK then serves every platform. Steps 3 and 4 are the fallback and use each platform's real, vendor-maintained native SDK: still no protocol code here, but two vendor SDKs to keep in step instead of one, so that route is taken only if outcome A proves impossible.

## Issues

- [ ] Confirm which cloud SDK versions work on the pinned iOS toolchain (macOS 12.7.6 / Xcode 14.2) before committing to step 3. No version bumps. This does not block steps 1 and 2.

## Steps

### Step 1: Gut the fake AWS code, then stop for review

Delete the hand-written client outright, before anything is put in its place. Mobile S3 is left broken at the end of this step, and that is the intended state: it makes the removal reviewable on its own, as a diff that only takes things away.

Delete these files:

- `packages/mobile-worker/src/shims/aws-s3.ts` (995 lines: S3 wire protocol, XML parsing, SigV4 signing)
- `packages/mobile-worker/src/shims/aws-lib-storage.ts` (112 lines: multipart upload)
- `packages/mobile-worker/src/test/shims/aws-s3.test.ts` (425 lines)
- `packages/mobile-worker/src/test/shims/aws-lib-storage.test.ts` (105 lines)

Edit `packages/mobile-worker/bundle.ts`:

- Remove the `"@aws-sdk/client-s3"` and `"@aws-sdk/lib-storage"` entries from `aliasMap` (around lines 43 and 44).
- Remove `@aws-sdk\/client-s3` and `@aws-sdk\/lib-storage` from the module filter regex (around line 58).

Then identify what the deletion orphans, and report it rather than removing it yet:

- `requestValidated` in `packages/mobile-worker/src/shims/node-https.ts`, which `aws-s3.ts` was the caller of. Check whether anything else calls it.
- `buildValidatedClientContext` in `apps/android-frontend/.../jsengine/TlsHost.java` and its iOS counterpart, reached through `requestValidated`.
- Any Node built-in shim that existed only to support the S3 client.

Do not delete orphans in this step. List them with file, symbol and remaining callers, so the decision to remove each one is made explicitly and not folded into a large diff.

**Stop here and report.** State the total lines removed, every file deleted, every file edited, and the orphan list. Do not begin step 2 until the removal has been reviewed.

Expected state at the end of this step:

- `bun run compile` is clean. If it is not, something outside the mobile worker depended on the shim, which is a finding worth reporting.
- `bun run test` passes, minus the two deleted shim test files.
- Mobile S3 fails. The desktop S3 test still passes, because the desktop always used the real SDK.

### Step 2: Measure whether the real JavaScript SDK loads in the engine

With the aliases gone, the engine now resolves `@aws-sdk/client-s3` to the real package. The shim was written when the engine had almost no shims; it now has `http`, `https`, `net`, `tls`, `crypto`, `stream`, `zlib`, `util` and more, so the real SDK may simply work.

1. Build the worker bundle (`bun run --filter=mobile-worker build:bundle`) and record what breaks: a bundle error, a missing Node built-in, or a runtime failure inside the engine.
2. Run the mobile S3 smoke test and record the result.

Outcome A: it works. Go to step 5. Steps 3 and 4 are not needed, and this is the better outcome: one SDK then serves every platform.

Outcome B: it does not. Write down the exact failure, including which module or built-in was missing. That failure is the justification for step 3 and must be written into this plan before any of step 3 is started. A missing Node built-in may be answerable by extending an existing shim, which is a smaller change than step 3 and must be considered first.

### Step 3: Add provider-agnostic storage host functions

Only if step 2 gives outcome B.

Mirror how the filesystem already works: the engine calls `host.fs*`, native does the work. Add the cloud equivalent, named for storage rather than for S3, so a second provider needs no new bridge:

- `cloudList(location, prefix, delimiter, max, next)`
- `cloudInfo(location, path)`
- `cloudRead(location, path, rangeStart, rangeEnd)`
- `cloudWrite(location, path, contentType, data)`
- `cloudDelete(location, path)`
- `cloudCopy(location, srcPath, destPath)`

`location` carries the provider and target (`s3:bucket`, later `azure:container`), so the switch on provider lives in native code, once.

Files:

- `packages/mobile-worker/src/lib/host-functions.ts`: add the six names to `EXPECTED_HOST_FUNCTIONS` and their types.
- `apps/android-frontend/.../jsengine/CloudHost.java` (new), registered in `HostBridge.java`, alongside `TcpHost`/`TlsHost`.
- `apps/ios-frontend/.../JsEngine/CloudHost.swift` (new), registered the same way.
- Native implementations call the real, vendor-maintained SDK on each platform (AWS SDK for Android, AWS SDK for Swift on iOS). They are thin adapters onto that SDK and nothing more: no request is signed, and no response is parsed, by code in this repository. If the pinned iOS toolchain cannot build a supported version, stop and report it rather than filling the gap by hand.

### Step 4: Make mobile `CloudStorage` a thin adapter

Only if step 2 gives outcome B.

- Add `packages/mobile-worker/src/shims/cloud-storage.ts`: an `IStorage` implementation over the six host functions, the same shape as the existing filesystem path.
- Change `aliasMap` in `bundle.ts` to alias `packages/storage`'s cloud storage to it. It must not alias any vendor SDK.

The engine then speaks no cloud protocol at all.

### Step 5: Clear the TLS coupling the shim forced

The deleted client stripped the URL scheme and always opened a validated TLS connection, whatever the user typed. Nothing forces that now, so an `http://` endpoint must reach an `http://` server.

- Remove the orphans listed in step 1, now that the decision on each has been reviewed: `requestValidated` in `packages/mobile-worker/src/shims/node-https.ts` if nothing else calls it, and `buildValidatedClientContext` in `apps/android-frontend/.../jsengine/TlsHost.java` and its iOS counterpart if they are only reachable through it. Confirm the LAN-share path does not need them before removing; it has its own TLS usage.
- Confirm an `http://` S3 endpoint is honoured end to end on device, not silently upgraded.

No certificate authority, trust anchor, TLS proxy or generated certificate is to be added to make the tests work. If any of that starts to look necessary, the scheme is still being overridden somewhere and that is the bug to fix.

### Step 6: Prove a second provider costs nothing

Only if step 2 gives outcome B, since outcome A already reaches every provider through the vendor's own JavaScript SDK.

Add a stub provider behind the same six host functions and confirm no JavaScript changes are needed to reach it. This is the check that the architecture actually fixed the problem rather than moving it.

## Unit Tests

- `packages/mobile-worker/src/test/cloud-storage.test.ts`: the new `IStorage` adapter against a fake host object, covering each method and the error envelope, in the style of the existing host-function tests.
- No unit tests for the native code; it is covered by the smoke tests, as the other host functions are.

## Smoke Tests

- The `s3-database` test on both platforms, unchanged in what it asserts, is the acceptance test for every step after step 1. It is expected to fail on mobile at the end of step 1, and that failure is the point of the review checkpoint.
- The encrypted-database, sync and prefetch-database tests exercise storage through the same path and must stay green throughout, including at the step 1 checkpoint.

## Verify

Steps 2 onward, once the removal has been reviewed:

- `bun run compile` is clean.
- `bun run test` passes.
- `bun run test:and` and `bun run test:electron` are fully green.
- `packages/mobile-worker/src/shims/aws-s3.ts` and `aws-lib-storage.ts` no longer exist.
- Every cloud request is made by a real, vendor-maintained SDK. Nothing in this repository signs a request or parses a cloud response: no SigV4, no credential-derivation, no XML/JSON response parsing for any provider.
- `packages/mobile-worker/bundle.ts` aliases no `@aws-sdk/*` module, and no alias replaces any other cloud vendor's SDK.
- Adding a second provider needs no new protocol code here, only configuration and a native call onto that provider's own SDK.
- The repository contains no certificate authority and no TLS proxy for testing.

## Notes

- **Step 1 deletes and stops.** Removal is reviewed as a diff that only takes things away, before anything is put back. Do not fold the replacement into the same change; a diff that removes 1600 lines and adds an SDK integration at once cannot be reviewed for what it removed.
- Step 2 may make steps 3, 4 and 6 unnecessary. Do not write them before running it.
- Roughly 1637 lines go in step 1: 995 (`aws-s3.ts`) + 112 (`aws-lib-storage.ts`) + 425 and 105 (their tests), plus three lines in `bundle.ts`. Use the real counts at the time, not these.
- The iOS toolchain is pinned at Xcode 14.2 / macOS 12.7.6. If the only usable native SDK needs newer, stop and ask rather than bumping.
- Mobile S3 is broken between step 1 and the end of step 2. That is expected and short-lived. It is not a reason to keep a copy of the deleted client anywhere, including commented out or on a branch "just in case": the file is in git history if it is ever wanted.
