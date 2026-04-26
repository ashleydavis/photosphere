# Fix Electron LAN Sharing Pairing Code Authority

## Overview

The Electron desktop app has the receiver generate the pairing code instead of the sender. This inverts the security model of the LAN sharing protocol: a receiver always knows its own pairing code hash, so the `GET /pairing-code-hash` verification is trivially passable by any rogue receiver on the network. The CLI implementation is correct (sender generates the code). This plan fixes the IPC handlers in main.ts, the preload bridge, the platform context interface, and all four share/receive UI dialogs so the sender always generates the code on both CLI and desktop, matching the documented security architecture.

## Issues

## Steps

1. **`apps/desktop/src/main.ts` — `start-share-receive` handler (lines 531–536)**
   Remove the receiver-side code generation (`Math.floor(...)` line 532). Change the handler to accept a `code: string` parameter passed from the renderer. Pass it directly to `activeReceiver.start(code)`. The handler no longer needs to return `{ code }` — change return type to void.

2. **`apps/desktop/src/main.ts` — `wait-for-receiver` handler (lines 558–561)**
   Add `code: string` as a second IPC argument. Change `new LanShareSender(payload)` to `new LanShareSender(payload, code)` so the sender is initialised with the caller-supplied code. Keep the return value as the raw endpoint (or null).

3. **`apps/desktop/src/main.ts` — `send-to-receiver` handler (lines 564–572)**
   Remove the `code: string` parameter from the handler signature. Remove `activeSender.pairingCode = code` (line 568). The sender now uses the code it was constructed with; no override is needed.

4. **`apps/desktop/src/preload.ts` — update three IPC bridge signatures (lines 107–121)**
   - `startShareReceive`: change to `(code: string): Promise<void>` and pass `code` to `ipcRenderer.invoke('start-share-receive', code)`.
   - `waitForReceiver`: change to `(payload: unknown, code: string): Promise<unknown>` and pass both args to invoke.
   - `sendToReceiver`: change to `(endpoint: unknown): Promise<boolean>` and remove the `code` arg from invoke.

5. **`packages/user-interface/src/context/platform-context.tsx` — update `IPlatformContext` interface (lines 401–428)**
   - `startShareReceive`: change to `(code: string) => Promise<void>`.
   - `waitForReceiver`: change to `(payload: unknown, code: string) => Promise<unknown>`.
   - `sendToReceiver`: change to `(endpoint: unknown) => Promise<boolean>`.
   Update the JSDoc comments on each method to reflect the new responsibilities.

6. **`packages/user-interface/src/components/share-database-dialog.tsx` — sender dialog (lines 32, 71, 96–143, 230–240, 268–278)**
   - Remove `"enter-code"` from the `ShareStep` type; replace it with `"showing-code"`.
   - In `handleStartSend`: generate a 4-digit code (`String(Math.floor(1000 + Math.random() * 9000))`), call `setPairingCode(code)` and `setStep("showing-code")`, then call `await platform.waitForReceiver(payload, code)`. If null, show error. Otherwise call `await platform.sendToReceiver(foundEndpoint)` (no code arg) and show success or error.
   - Replace the `"enter-code"` JSX block (lines 230–240) with a `"showing-code"` block that displays the 4-digit code in large text and says "Tell the receiver to enter this code."
   - Replace the `"enter-code"` actions block (lines 268–278) with a `"showing-code"` block that shows only a Cancel button (auto-sends once receiver is found).

7. **`packages/user-interface/src/components/share-secret-dialog.tsx` — sender dialog (lines 31, 39, 56–101, 144–153, 182–192)**
   Apply the same changes as step 6: rename `"enter-code"` to `"showing-code"`, generate code before calling `waitForReceiver`, display it during the showing-code step, auto-send with `sendToReceiver(endpoint)` (no code arg).

8. **`packages/user-interface/src/components/receive-database-dialog.tsx` — receiver dialog (lines 32, 93–158, 289–308)**
   - Add `"enter-code"` to the `ReceiveStep` type and set it as the initial step.
   - Add `enteredCode` state (`useState("")`).
   - Add an `"enter-code"` JSX block with a text input for the pairing code and a "Start" button (disabled until 4 digits entered).
   - Move the `startReceiving` async function into a new `handleStartReceiving` callback triggered by the Start button click, rather than a `useEffect` that fires on dialog open.
   - Inside `handleStartReceiving`: call `await platform.startShareReceive(enteredCode)`, then `setStep("waiting")`, then `await platform.waitShareReceive()` for the payload.
   - Remove the display of `pairingCode` state in the `"waiting"` block (line 291–307); replace with a simple spinner and "Waiting for sender..." message.
   - Remove the `pairingCode` state variable entirely (receiver no longer shows a code).

9. **`packages/user-interface/src/components/receive-secret-dialog.tsx` — receiver dialog (lines 28, 52–108, 144–163)**
   Apply the same changes as step 8: add `"enter-code"` as initial step, add `enteredCode` state, add code-entry JSX block, move receiver start into a triggered callback, remove pairingCode display.

## Unit Tests

There are no existing unit tests for the IPC handlers in `apps/desktop/src/main.ts` or for the UI dialog components. No new unit tests are required by this change — the underlying `LanShareSender` and `LanShareReceiver` classes are already tested in `packages/lan-share/src/test/` and this plan does not change them.

## Smoke Tests

- **Desktop send database**: Open desktop app, click Share on a database. Confirm the "showing-code" step displays a 4-digit code. On a second device (or the CLI receiver), start a receiver and enter the displayed code. Confirm the transfer completes and the database appears on the receiver.
- **Desktop receive database**: Open desktop app, click Receive Database. Confirm the dialog shows a code-entry input. On a second device (or the CLI sender), start a sender; read its displayed code and type it in the receive dialog, then click Start. Confirm the payload arrives and can be saved.
- **Desktop send secret**: Same as above for secrets (Share button on a secret → showing-code step → receiver enters code → success).
- **Desktop receive secret**: Same as above for receiving a secret.
- **CLI send → Desktop receive**: Run `psi secrets send` on the CLI (code displayed on CLI), click Receive Secret on the desktop and enter the CLI's code. Confirm the secret is received.
- **Desktop send → CLI receive**: Click Share on a desktop secret (code displayed in dialog), run `psi secrets receive` on CLI and enter the code. Confirm the secret is received.
- **Wrong code rejection**: Enter an incorrect code on the receiver. Confirm the sender reports a pairing code mismatch and does not deliver the payload.

## Verify

- `bun run compile` from repo root passes with no TypeScript errors.
- `bun run test` from repo root passes (lan-share unit tests still green).
- Manual smoke test: one full send/receive round-trip succeeds on the desktop app.

## Notes

- The code generation expression `String(Math.floor(1000 + Math.random() * 9000))` is identical to the one in `packages/lan-share/src/lib/lan-share-sender.ts` (`generatePairingCode`). It is intentionally duplicated in the UI so the code is visible before the blocking `waitForReceiver` IPC call returns.
- The `"waiting"` step in the receive dialogs no longer needs to display a code, only a spinner. The receiver's job is to listen quietly until the sender (who knows the code) connects.
- No changes are needed to the CLI (`apps/cli/src/cmd/secrets.ts` and `apps/cli/src/cmd/dbs.ts`); the CLI already implements the correct pattern.
- No changes are needed to `packages/lan-share/` — the underlying `LanShareSender` and `LanShareReceiver` classes are correct.
