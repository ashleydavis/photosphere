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

**The route is decided: the real JavaScript AWS SDK runs inside the engine.** One vendor SDK then serves web, desktop, CLI, iOS and Android, and a second provider later arrives the same way, as that vendor's own JavaScript SDK bundled into the worker.

The rejected alternative was a native SDK per platform behind provider-agnostic `host.cloud*` functions. It satisfies the requirement too, but costs two vendor SDKs to keep in step instead of one, new native code on both platforms, and a fresh round of the same work for every provider added later. It is not in this plan.

## Issues

None.

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

### Step 2: Make the real JavaScript SDK run in the engine

With the aliases gone, the engine resolves `@aws-sdk/client-s3` to the real package. The shim was written when the engine had almost no shims; it now has `http`, `https`, `net`, `tls`, `crypto`, `stream`, `zlib`, `util` and more, so most of what the SDK needs is already there.

Build the worker bundle (`bun run --filter=mobile-worker build:bundle`) and run the mobile S3 smoke test. Fix whatever they surface, working from these two rules:

- **A missing Node built-in is answered by extending an existing shim**, or adding one for that built-in. That is what the shims are for. Note that `zlib`, `stream`, `crypto` and the rest already exist and are more likely to need a few extra exports than wholesale replacement.
- **Nothing in this repository may sign a request or parse a cloud response.** If a fix starts to look like reimplementing part of the SDK, stop and report it rather than writing it.

One obstacle is already known. `bundle.ts` targets `browser`, so Bun honours the `browser` field in the AWS SDK's package.json files and selects variants written for a DOM: a `fetch`-based HTTP handler, `ReadableStream`, `TextEncoder`, `btoa`. The engine has none of those; what it has is Node-shaped shims. The SDK's node variants are the ones that fit, and the vendor already ships both, so this is a resolution problem, not a missing-capability one.

The engine also has no outbound plain-TCP transport: `node-net.ts` can accept connections but not open one. An `http://` endpoint needs one, so expect to add it alongside the existing `tcpListen`.

### Step 3: Clear the TLS coupling the shim forced

The deleted client stripped the URL scheme and always opened a validated TLS connection, whatever the user typed. Nothing forces that now, so an `http://` endpoint must reach an `http://` server.

- Remove the orphans listed in step 1, now that the decision on each has been reviewed: `requestValidated` in `packages/mobile-worker/src/shims/node-https.ts` if nothing else calls it, and `buildValidatedClientContext` in `apps/android-frontend/.../jsengine/TlsHost.java` and its iOS counterpart if they are only reachable through it. Confirm the LAN-share path does not need them before removing; it has its own TLS usage.
- Confirm an `http://` S3 endpoint is honoured end to end on device, not silently upgraded.

No certificate authority, trust anchor, TLS proxy or generated certificate is to be added to make the tests work. If any of that starts to look necessary, the scheme is still being overridden somewhere and that is the bug to fix.

## Unit Tests

There is no new storage abstraction to test: `packages/storage`'s `CloudStorage` is unchanged and already covered. The tests belong to whatever shim work step 2 turns out to need.

- Every shim function added or changed in step 2 gets unit tests against a mock host, in the style of the existing `src/test/shims` suites.
- The trust-mode rule from step 3 gets a test in each direction: an ordinary request validates, and only an explicit opt-out gets the caller-pins-it behaviour LAN share relies on.
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
- `packages/mobile-worker/bundle.ts` aliases no `@aws-sdk/*` or `@smithy/*` module, and no alias replaces any other cloud vendor's SDK. Choosing between variants the vendor already ships is not aliasing it away.
- Adding a second provider needs no new protocol code and no new native code: it arrives as that vendor's own JavaScript SDK, bundled the same way, on every platform at once.
- The repository contains no certificate authority and no TLS proxy for testing.

## Notes

- **Step 1 deletes and stops.** Removal is reviewed as a diff that only takes things away, before anything is put back. Do not fold the replacement into the same change; a diff that removes 1600 lines and adds an SDK integration at once cannot be reviewed for what it removed.
- Roughly 1637 lines go in step 1: 995 (`aws-s3.ts`) + 112 (`aws-lib-storage.ts`) + 425 and 105 (their tests), plus three lines in `bundle.ts`. Use the real counts at the time, not these.
- Mobile S3 is broken between step 1 and the end of step 2. That is expected and short-lived. It is not a reason to keep a copy of the deleted client anywhere, including commented out or on a branch "just in case": the file is in git history if it is ever wanted.
- The mobile worker currently has no CA-validated TLS path at all: the validated mode went with the deleted client, leaving only LAN share's caller-pins-it mode. Step 2 needs validated TLS back, as a new capability rather than a leftover recovered.
