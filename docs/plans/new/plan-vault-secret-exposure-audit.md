# Vault and keychain secret exposure audit

## Overview

The vault package (`packages/vault`) is the one place Photosphere holds S3 credentials, database encryption keys and user secrets, and every platform reaches its OS keychain by spawning a command line tool. Two of those three platforms currently hand the secret to the tool as a command-line argument, which puts it in the process table where any other user on the machine can read it, and the shared error path in `runCommand` prints the whole argument list into its error message, so a failed store can copy the secret into whatever logs that error. This plan audits the vault and its callers for exposure of that kind, fixes what it finds, and adds tests that fail when a secret reaches a place it should not. It covers the plaintext vault's file permissions, the mobile vault shim, and the paths outside the package that carry secret values (the CLI secrets commands, LAN sharing, and the app log files).

## Issues

## Steps

1. **Record the exposure surface before changing anything.** Create `docs/plans/new/vault-audit-findings.md` and, as each step below establishes a fact, append the file, line and what was observed. This is the evidence trail for the audit, and it is what makes a later "no issue here" reviewable rather than asserted. Delete nothing from it; a finding that turns out to be benign is recorded as benign with the reason.

2. **Confirm the macOS argv exposure.** `packages/vault/src/lib/macos-keychain-vault.ts` `set()` calls `runCommand([SECURITY_TOOL, "add-generic-password", "-U", "-s", ..., "-a", ..., "-w", json])`, where `json` is the secret payload. Establish by observation, not by reading: write a scratch script that stores a secret with a known marker value through `MacOSKeychainVault.set()` while a loop samples `ps -eo args`, and record whether the marker appears. On Linux (this machine) the equivalent check cannot run, so record that this specific check is unverified here and must run on macOS. Do not skip the check and assert the conclusion from the source.

3. **Fix the macOS store to keep the secret off the command line.** Change `set()` in `macos-keychain-vault.ts` to pass the payload to `security` through stdin rather than as the `-w` argument. `runCommand` in `packages/vault/src/lib/keychain-types.ts` already opens stdin as a pipe but never writes to it; extend it with a way to supply stdin content, keeping the existing no-stdin behaviour for every current caller. Name the new capability explicitly (for example a separate `runCommandWithInput(args, input)`) rather than adding an optional parameter, since optional parameters are not used in this codebase.

4. **Confirm and fix the Windows exposure.** `packages/vault/src/lib/windows-keychain-vault.ts` builds a PowerShell script with the secret JSON interpolated into it and passes the whole script as the `-Command` argument, so the secret is in argv exactly as on macOS. It is also subject to PowerShell script-block logging and transcription, which write command text to the Windows event log. Change `runPowerShell` to feed the script to PowerShell on stdin (`powershell -NoProfile -Command -`), and pass the secret itself as an environment variable the script reads rather than as literal text inside the script. Verify on Windows, or record it as unverified with the reason.

5. **Audit the PowerShell escaping.** The Windows vault escapes single quotes by doubling them (`replace(/'/g, "''")`) and interpolates the result into a single-quoted PowerShell string. Establish whether a secret value or secret name containing a newline, a backtick, or `$(...)` can break out of that string or corrupt the script. Write a unit test in `packages/vault/src/test/windows-keychain-vault.test.ts` that passes such values through the script-building code and asserts the produced script is not malformed. If step 4 moves the secret to an environment variable, the value no longer needs escaping, but the service and account names still do.

6. **Stop `runCommand` printing arguments in its error message.** `keychain-types.ts` rejects with ``Command "${args.join(" ")}" exited with code ${code}. stderr: ${stderr}``. On macOS today that string contains the secret. Change it to name the command only (`args[0]`) and the exit code, and keep stderr. Establish separately whether the tools write secret values to their own stderr; if any does, redact that too. Add a unit test asserting that an error from a failed command does not contain the value that was passed.

7. **Trace where a vault error can be written to disk.** Find every place a caught error from the vault is logged: the CLI's error log (the smoke tests reference `/tmp/photosphere/logs/psi-*-errors.log`), the Electron main process log, and the mobile worker's host error envelopes. For each, establish whether the error message or a stack trace can carry a secret value, and record the answer. Fix any that can by redacting at the point of logging, not by making the vault throw less information.

8. **Audit the plaintext vault's on-disk protection.** In `packages/vault/src/lib/plaintext-vault.ts`, `ensureDir` creates the vault directory 0700 and `applyFileMode` sets the file 0600, both swallowing chmod failures. Establish: (a) that the temp file `updateFileOptimistic` renames into place cannot be read by another user before `applyFileMode` runs, given the 0700 directory; (b) what protection exists on Windows, where both chmod calls are no-ops and the directory inherits default ACLs; (c) whether the lock file `updateFileOptimistic` creates beside the vault ever contains secret contents. Record each answer. Fix (b) if the answer is "none", or record plainly that the plaintext vault is unprotected on Windows and that this is what "plaintext" means.

9. **Check that nothing silently falls back to the plaintext vault.** `getDefaultVaultType()` in `packages/vault/src/lib/get-vault.ts` returns `PHOTOSPHERE_VAULT_TYPE ?? "keychain"`. Establish that no code path downgrades to `plaintext` when the keychain is unavailable, and that `instantiateVault` throwing on an unknown type is not caught somewhere that substitutes plaintext. A user whose keychain is missing must get a loud failure, not silent plaintext storage. Add a unit test in `packages/vault/src/test/get-vault.test.ts` covering the unknown-type and unsupported-platform throws.

10. **Audit the mobile vault shim.** `packages/mobile-worker/src/shims/vault.ts` reads secrets through the `secureStoreGet` host function. Establish: whether a secret value returned by `secureStoreGet` can end up inside a task payload, a task result, a queue record, or a host-bridge log line; and what the native SecureStore implementations on Android and iOS actually store into (the Android Keystore / EncryptedSharedPreferences and the iOS Keychain, or something weaker). Record what each platform uses. This is a read-only step: report what is found rather than changing native code.

11. **Sweep the callers for secrets in transit.** Grep for the places a secret value is read and then passed onward: `apps/cli/src/cmd/secrets.ts`, the LAN share send/receive paths, and `resolveStorageCredentials`. For each, establish whether the value can reach stdout, a log, a URL, an error message, or a file that is not the vault. Record each path. The LAN share paths matter most because they put secrets on the network.

12. **Check the repository and test fixtures for committed secrets.** Establish whether any real-looking secret is committed: search the tree and the git history for vault files, `databases.toml` entries carrying keys, and the seeded credentials in the smoke tests (`seed_secret`, `seed_encryption_key` in `cli-desktop-lan-share-smoke-tests.sh` and `apps/cli/smoke-tests/lib/common.sh`). Test fixtures using obvious dummy values (`AKIATEST`, `secret123`) are fine and should be recorded as fine; anything that looks real is a finding.

13. **Write the findings up.** Once every step above has an answer, rewrite `docs/plans/new/vault-audit-findings.md` into a report: what was checked, what was found, what was fixed, what was left and why, and which checks could not run on this machine. Every claim must name the file and line it came from, and must say whether it was observed or read.

## Unit Tests

- `packages/vault/src/test/keychain-types.test.ts` (new): `runCommand` rejects with an error whose message does not contain any argument beyond the command name; the new stdin-supplying variant writes its input to the child's stdin and closes it.
- `packages/vault/src/test/macos-keychain-vault.test.ts`: `set()` passes the secret payload through stdin and does not place it in the spawned argument list.
- `packages/vault/src/test/windows-keychain-vault.test.ts`: the generated PowerShell script is well formed for secret names and values containing a single quote, a double quote, a newline, a backtick and `$(...)`; `set()` does not place the secret value in the argument list.
- `packages/vault/src/test/plaintext-vault.test.ts`: the vault file is 0600 and the directory 0700 after a write on a platform that supports POSIX modes; a write that fails part way leaves the previous contents rather than a truncated file.
- `packages/vault/src/test/get-vault.test.ts`: an unknown vault type throws; the keychain type on an unsupported platform throws; no path returns a `PlaintextVault` for a type other than `plaintext`.
- `packages/mobile-worker/src/test/shims/vault.test.ts`: an unavailable keychain throws rather than returning undefined, and a secret value is not included in anything the shim returns other than the secret itself.

## Smoke Tests

- `apps/cli/keychain-smoke-tests.sh`: add a check that stores a secret with a known marker value while sampling the process table, and fails if the marker appears in any command line. This is the end-to-end form of steps 2 and 4 and is the only check that covers the real OS tool rather than a mock. It runs per platform in the Release workflow, which is where the macOS and Windows answers come from.
- `apps/cli/keychain-smoke-tests.sh`: add a check that a failed store (for example against a service name that cannot be written) produces an error message on stderr that does not contain the secret value.
- `apps/cli/smoke-tests.sh`: add a check that after a run which stores and reads secrets, no file under the CLI's log directory contains any of the secret values the run used.

## Verify

- `bun run compile` passes.
- `bun run test` passes, including the new and changed vault unit tests.
- `bun run test:cli` passes.
- `bun run test:everything -- --force` passes on this platform, or its failures are ones that predate this work and are named.
- The keychain smoke tests pass on Linux locally, and the macOS and Windows results are read from a Release workflow run rather than assumed. `apps/cli/keychain-smoke-tests.sh` is not currently run by any workflow job or any `bun run` aggregate, so wiring it into the Release workflow per platform is part of this plan's verification, not an optional extra.
- `docs/plans/new/vault-audit-findings.md` exists and every step above has an entry, including the ones whose answer was "no issue".

## Notes

- **Three findings are already established from reading the source and are the reason for this plan.** `macos-keychain-vault.ts:116` passes the secret as the `-w` argument; `windows-keychain-vault.ts` interpolates it into a script passed as `-Command`; `keychain-types.ts` puts the full argument list into its error message. The Linux vault already pipes the secret to `secret-tool` on stdin and is the model the other two should follow.
- **Nothing in this plan has been observed running.** The three findings above are readings of the code, not reproductions. Step 2 exists because the difference matters.
- **The macOS and Windows checks cannot run on this machine**, which is Linux. Any step that claims a macOS or Windows result without a Release workflow run behind it is unverified and must say so.
- **`apps/cli/keychain-smoke-tests.sh` is currently run by nothing.** It is not in the Release workflow, not in `test:all`, and not in `test:everything`. That is the same class of gap that let a broken suite survive for five days, and it is why the smoke tests above are worth adding only if the suite is also wired into the workflow.
- **The plaintext vault is unencrypted by design** and says so in its own comment. The audit's job is not to encrypt it but to establish that it is never selected without the user asking for it, and that its file permissions are what they claim to be.
- **Do not replace any OS keychain integration with a hand-written substitute.** If a platform's tool cannot be used safely, that is a finding to report, not something to work around.
