# Security audit: CLI, desktop and mobile

## Overview

Photosphere holds a user's whole photo library, the S3 credentials that reach it, and the keys that encrypt it, and it exposes that across three apps, a LAN sharing protocol, several local HTTP servers, an Electron renderer, and a mobile WebView with a thirty-function native bridge. None of it has been audited. This plan is the first pass: a breadth-first sweep that maps every place untrusted data or a secret crosses a boundary, checks each one against a fixed set of questions, and produces a written report of what is wrong. Its second job is triage: it names the areas whose risk is too concentrated to cover in a sweep and writes a separate, deeper audit plan for each. It deliberately does not try to be the deep audit of any one area, because a sweep that stops to fully audit the crypto never reaches the mobile bridge.

## Issues

## Steps

1. **Create the findings file and the boundary map.** Write `docs/plans/new/security-audit-findings.md` with two sections: a boundary inventory and a findings list. Populate the inventory by enumerating, with file and line for each: every network listener (`packages/rest-api/src/lib/asset-server.ts`, `packages/lan-share-network/src/lib/lan-share-receiver.ts` and `lan-share-sender.ts`, `apps/desktop/src/lib/test-control-server.ts`, `apps/desktop/src/lib/mcp/server.ts`); every Electron IPC channel and everything the preload exposes (`apps/desktop/src/preload.ts`, `apps/desktop/src/main.ts`); every Capacitor plugin method reachable from the mobile WebView (`apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/`, and the iOS equivalents); every host function the embedded worker can call (`packages/mobile-worker/src/shims/`); and every place the CLI takes a path, URL or credential from its arguments. Each entry records what crosses the boundary and who is on the other side. Every finding in later steps must point at an inventory entry.

2. **Ask one fixed set of questions of every boundary.** For each inventory entry, record an answer with evidence: who can reach it (any user on the machine, anyone on the LAN, only this process); what authenticates or authorises the caller; what happens to a malformed or hostile input; whether a secret can cross it or be logged at it; and whether it is enabled in a shipped build or only under a test flag. An entry whose answer is "no authentication" is not automatically a finding, but it must say what stands in place of authentication.

3. **Confirm the LAN share pairing weaknesses.** `packages/lan-share-network/src/lib/lan-share-sender.ts:22` generates the pairing code with `Math.floor(1000 + Math.random() * 9000)`. Establish two things by observation: that `Math.random()` is used rather than `crypto.randomInt`, so the code is predictable rather than unguessable; and that the receiver's `GET /pairing-code-hash` endpoint returns the SHA-256 of that code, which reduces recovering it to hashing 9000 candidates. Write a scratch script that takes a hash from a live receiver and recovers the code by brute force, and record how long it takes. Then establish what the pairing code actually protects: read the receiver in `lan-share-receiver.ts` and record whether knowing the code is sufficient to receive a shared secret or database.

4. **Fix the pairing code generation.** Change `generatePairingCode` in `lan-share-sender.ts` to use `randomInt` from `node:crypto`. This is the cheap half of step 3 and can land regardless of what the rest of the audit decides about the protocol. Keep the code four digits: the length is a usability decision that is not this plan's to make, and the report should say plainly that four digits is 9000 possibilities whatever generator produces them.

5. **Record the hash endpoint as a finding rather than fixing it.** Removing or changing `GET /pairing-code-hash` changes the protocol on both sides and affects the CLI, desktop and mobile senders and receivers together. Write it up with the brute-force timing from step 3, name the options (drop the endpoint, replace the exchange with a password-authenticated key agreement, lengthen the code), and leave the decision. Do not redesign the protocol inside a triage sweep.

6. **Audit the local HTTP servers.** `asset-server.ts:85` and `test-control-server.ts:201` both bind `127.0.0.1`, which limits them to this machine but not to this user. Establish for each: whether any authentication exists, what an unauthenticated local process can read or do through it, and whether the port is discoverable. For `test-control-server.ts`, establish that it cannot start in a packaged build: `main.ts` starts it when `PHOTOSPHERE_TEST_MODE=1`, and the question is whether a user or another process can set that environment variable for a shipped app. That is a finding if the answer is yes, because the server drives the UI.

7. **Audit the MCP server.** `apps/desktop/src/lib/mcp/` runs in a worker with a bridge to the main process (`main-bridge.ts`, `ipc.ts`, `sender.ts`) and exposes tools under `tools/`. Establish what transport it listens on, what authenticates a client, what each tool can reach, and whether a tool can be driven into reading or writing a path outside the open database. An MCP server is an intentional remote-control surface, so the question is not whether it is powerful but whether anything limits who drives it.

8. **Audit the Electron configuration.** `apps/desktop/src/main.ts:106` sets `nodeIntegration: false` and `contextIsolation: true`, which are the two that matter most. Establish the rest: whether `sandbox` is enabled, whether a Content Security Policy is set on the renderer, what `preload.ts` exposes on the context bridge and whether any of it takes a path or a command from the renderer, whether `will-navigate` and `setWindowOpenHandler` are restricted, and what `main.ts:122` puts in the renderer URL. The generic `main-command` IPC channel is the one to look at hardest, because it dispatches named actions from the renderer.

9. **Audit the mobile bridge surface.** The WebView can call every Capacitor plugin method, and the embedded worker can call thirty host functions. Establish: what `SecureStorePlugin` exposes to the WebView and whether the WebView can read secrets it did not write; what the `JsEngine` plugin will execute and whether the script it runs can come from anywhere but the app bundle; whether the host functions that touch the filesystem constrain paths to the app sandbox; and what `MainActivity.java:35` injects as `globalThis.__PHOTOSPHERE_TEST__`, in particular whether it is present in a release build. Do the same for the iOS side.

10. **Audit input handling on untrusted data.** The apps parse image and video files, `databases.toml`, `vault.json`, LAN share payloads, and S3 responses, and they shell out to ImageMagick and ffmpeg. Establish for each parser what a malformed input does, and for each shell-out whether any part of the command line comes from a filename or other user-controlled string. A filename reaching a shell is a command injection; a filename reaching an argument list is not, and the report must distinguish them rather than flagging every `spawn`.

11. **Audit the dependency surface.** Run the package manager's audit over `bun.lock` and record what it reports. Separately, list the dependencies that handle untrusted input or credentials (the AWS SDK, the image and video tooling, the HTTP stack, anything in the LAN share path) and record their versions and whether they are current. Do not upgrade anything as part of this plan: an upgrade is a change with its own test burden and belongs in its own piece of work.

12. **Check for committed secrets and for secrets in the build outputs.** Search the tree and the git history for credentials, keys and tokens. Separately, establish whether any secret reaches a shipped artifact: check what `bun run bundle` and the mobile builds embed, and whether any environment variable read at build time carries a credential into the bundle. Dummy test fixtures are recorded as fine, with the reason.

13. **Write the report and the triage list.** Rewrite `docs/plans/new/security-audit-findings.md` into the deliverable: every boundary with its answers, every finding with file, line, what an attacker gets and how confident the finding is, and a plain list of what was checked and found sound. Then write the triage: the areas whose risk is concentrated enough to need their own audit, each with a one-paragraph justification. Expect at least the encryption package, the LAN share protocol, and the mobile native bridge, on the evidence below. The vault already has its own plan in `docs/plans/new/plan-vault-secret-exposure-audit.md` and must be listed as already covered rather than re-audited here.

14. **Write a plan file for each triaged area.** For each area from step 13, write `docs/plans/new/plan-<area>-security-audit.md` following the same structure as the vault plan: concrete steps, the questions to answer, what to fix inline and what to only report. These are plans, not implementations. Do not begin any of them.

## Unit Tests

- `packages/lan-share-network/src/test/lan-share-sender.test.ts`: `generatePairingCode` returns a four-digit code in the range 1000 to 9999 across many calls, and draws from `node:crypto` rather than `Math.random`.
- One regression test per confirmed and fixed finding, in the package that owns it. A finding that is reported rather than fixed gets no test, because there is nothing yet to hold in place.
- No tests are written for findings in native Android or iOS code, or for anything in the shell harness, per the repository's rules on both.

## Smoke Tests

- Extend `apps/cli/smoke-tests-lan-share.sh` with a check that a receiver rejects a share offered with the wrong pairing code, so the code is proven to be doing something rather than assumed to be.
- Add an end-to-end check for any confirmed finding that is fixed and is reachable from a running app. For a triage sweep most findings will be reported rather than fixed, so this list is expected to stay short.
- Do not write a smoke test that itself performs an attack against anything outside this machine.

## Verify

- `bun run compile` passes.
- `bun run test` passes, including the new pairing code test.
- `bun run test:cli` and `bun run test:cli:lan-share` pass.
- `bun run test:everything -- --force` passes on this platform, or its failures are named and predate this work.
- `docs/plans/new/security-audit-findings.md` exists, every boundary in the inventory has an answer to all five questions from step 2, and every finding names a file and line.
- A plan file exists in `docs/plans/new/` for each triaged area.

## Notes

- **Two findings are already established from reading the source, and they are why this plan starts where it does.** `lan-share-sender.ts:22` uses `Math.random()` for the pairing code, and the receiver serves the SHA-256 of that code from `GET /pairing-code-hash`, which is 9000 candidates and therefore recoverable instantly by anyone on the LAN. Neither has been reproduced; step 3 exists to reproduce them before anything is claimed.
- **A third area looks serious enough to name now.** `packages/encryption` uses AES-256-CBC (`encrypt-buffer.ts:22`, `encrypt-stream.ts:33`) with no authentication tag and no separate MAC. Unauthenticated CBC is malleable: an attacker who can write to the storage can alter ciphertext without detection, and padding errors on decryption can leak information. This is exactly the kind of thing a sweep should identify and hand to a dedicated audit rather than try to settle in passing, and it is the strongest candidate for step 14.
- **What already looks right** should be recorded as such rather than passed over: `nodeIntegration: false` and `contextIsolation: true` in `main.ts`, both local HTTP servers binding `127.0.0.1` rather than `0.0.0.0`, the LAN share using HTTPS with certificate pinning, and the Linux vault piping its secret to `secret-tool` on stdin. An audit that reports only problems gives no sense of what the baseline is.
- **This plan finds and reports; it fixes almost nothing.** The one exception is the pairing code generator, because that fix is a single call with no protocol consequence. Everything else is written up and left, because a security fix made in passing during a sweep is a change nobody reviewed.
- **Scope limits worth stating.** No penetration testing against anything but this machine. No dependency upgrades. No changes to native Android or iOS code. No redesign of the LAN share protocol.
- **The macOS and iOS halves cannot be checked on this machine**, which is Linux, and the local iOS environment is fixed at macOS 12.7.6 with Xcode 14.2. Any step producing an Apple-platform answer must say whether it was observed or inferred.
