# Plan: LAN Sharing Mutual Pairing Code Authentication

## Problem

The current LAN sharing protocol only authenticates in one direction: the receiver verifies the sender knows the pairing code, but the sender has no way to verify it is talking to the correct receiver. This means a malicious device on the same network could impersonate a receiver, accept the sender's connection, and steal the payload before the real receiver ever sees it.

## Solution

Move pairing code generation to the sender and add a `GET /pairing-code-hash` endpoint on the receiver so the sender can verify the receiver knows the pairing code before transmitting the payload. The receiver also continues to verify the pairing code hash when the payload arrives, giving full mutual authentication.

**Revised flow:**

1. Sender generates the 4-digit pairing code and displays it to the user.
2. Receiver starts its HTTPS server and begins broadcasting on UDP as before.
3. User reads the pairing code off the sender's screen and enters it on the receiver.
4. Sender discovers the receiver via UDP, pins the TLS certificate fingerprint.
5. Sender calls `GET /pairing-code-hash` on the receiver — the receiver returns `hash(entered_code)`.
6. Sender computes `hash(its_code)` and compares. If they don't match, it aborts.
7. Sender posts `{ codeHash, payload }` to `POST /share-payload`.
8. Receiver verifies the pairing code hash again before accepting the payload.

---

## Files to Change

### `packages/lan-share/src/lib/lan-share-types.ts`

Add a response type for the new endpoint and rename the existing hash field:

```typescript
export interface IPairingCodeHashResponse {
    codeHash: string;
}
```

Update `IShareRequest` to rename `pinHash` → `codeHash`:

```typescript
interface IShareRequest {
    codeHash: string;
    payload: unknown;
}
```

---

### `packages/lan-share/src/lib/lan-share-receiver.ts`

**1. Remove pairing code generation**

Delete `generatePairingCode()` and the call to it. The receiver no longer creates or owns the pairing code. It now receives the code from the user via a UI prompt or CLI input.

**2. Accept pairing code from caller**

Change the receiver's public API so that the pairing code is provided by the caller rather than generated internally. Options:

- `start(code: string)` — receiver accepts the plain code string, hashes it internally.
- `start(codeHash: string)` — caller hashes before passing in.

Prefer accepting the plain code so the hashing stays in one place inside the library.

**3. Add `GET /pairing-code-hash` endpoint**

In `handleRequest()`, add a route for `GET /pairing-code-hash` that returns:

```json
{ "codeHash": "<hash of pairing code>" }
```

This endpoint must be available as soon as the server starts (before any payload is received).

**4. Rate limit all incoming requests**

A legitimate share requires exactly one `GET /pairing-code-hash` and one `POST /share-payload` — two requests total. The receiver should maintain a global request counter and abort the share entirely after a small threshold (e.g. 5 requests) regardless of endpoint or outcome. Any excess indicates something unexpected on the network.

```typescript
private requestCount = 0;
private readonly MAX_REQUESTS = 5;

private handleRequest(req, res) {
    this.requestCount++;
    if (this.requestCount > this.MAX_REQUESTS) {
        res.writeHead(429);
        res.end();
        this.abort(); // stop server and UDP broadcast
        return;
    }
    // ... route to /pairing-code-hash or /share-payload
}
```

This replaces the existing per-endpoint failure counter on `POST /share-payload` (the old "3 failed attempts" logic). The global counter is simpler and covers both endpoints.

**5. Keep `POST /share-payload` pairing code verification unchanged**

The receiver still checks `codeHash` on the incoming payload and rejects with 403 if it doesn't match. This remains the second layer of defence, now covered by the global request budget rather than its own separate counter.

**6. Update display / callback**

Currently the receiver exposes the pairing code to the UI via a callback or return value from `start()`. Remove this — the code now comes from the user (entered on the receiver device), not generated here. The receiver should instead accept the code as an argument and expose a way to signal "waiting for sender" to the UI.

---

### `packages/lan-share/src/lib/lan-share-sender.ts`

**1. Generate pairing code**

Add `generatePairingCode()` to the sender (move it from the receiver). Return a random 4-digit string (1000–9999).

**2. Expose pairing code to caller before sending**

The sender must display the pairing code to the user before attempting to connect. Add a method or make the code accessible on construction:

```typescript
const sender = new LanShareSender(payload);
console.log("Pairing code:", sender.pairingCode); // user reads this, enters it on receiver
const endpoint = await sender.waitForReceiver(60000);
await sender.send(endpoint); // pairing code no longer passed here — it's already on the instance
```

**3. Add pre-send verification step**

In `send(endpoint)`:

1. Make a `GET /pairing-code-hash` request to the receiver (using the same cert-pinned HTTPS connection).
2. Compare the returned `codeHash` against `hash(this.pairingCode)`.
3. If they don't match, throw an error (do not send the payload).
4. If they match, proceed with `POST /share-payload` as before.

The `GET /pairing-code-hash` request must use the same certificate fingerprint pinning logic already used for `POST /share-payload`.

---

### `apps/cli/src/cmd/dbs.ts`

**`psi dbs send`**

- Before doing anything else, print a notice that both devices must be on the same local network (wired or Wi-Fi) and that this does not work over the internet.
- Display the pairing code to the user immediately after creating the sender, before calling `waitForReceiver`.
- Remove the prompt asking the user to enter a code — the code is now generated by the sender, not read from the receiver's screen.
- Remove the `--code` flag (or keep it for scripted/non-interactive use to provide a deterministic pairing code).

**`psi dbs receive`**

- Before doing anything else, print the same local-network notice.
- After calling `receiver.start()`, prompt the user to enter the pairing code shown on the sender's screen instead of displaying a generated code.
- Pass the entered code to `receiver.start(code)`.

---

### `apps/cli/src/cmd/secrets.ts`

Same changes as `dbs.ts` — mirror the send/receive flow updates, including the local-network notice at the start of both send and receive.

---

### Desktop app (if applicable)

If there is a desktop UI for send/receive, the same direction reversal applies:

- **Send dialog**: show a notice that both devices must be on the same local network (wired or Wi-Fi) and that this does not work over the internet. Show the generated pairing code and instruct the user to enter it on the receiver device.
- **Receive dialog**: show the same local-network notice. Show a text input for the user to type the pairing code shown on the sender.

---

---

## Remove `shared:` Prefix from Secret Names

Imported secrets are currently stored in the vault with a `shared:` prefix (e.g. `shared:abc12345`). This is an internal implementation detail that leaks into user-visible secret names. Remove it — secrets imported via LAN sharing should be named the same way as any other secret.

**Files to change:**

- `apps/cli/src/cmd/secrets.ts` — remove `shared:` prefix when constructing `saveName`
- `apps/cli/src/cmd/dbs.ts` — remove `shared:` prefix from secret names constructed during database import; remove the `.startsWith('shared:')` filter and `.slice('shared:'.length)` calls that rely on the prefix
- `apps/desktop/src/main.ts` — remove `shared:` prefix from all vault key lookups
- `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` — remove `shared:` prefix from vault get/set/delete calls and the `.startsWith('shared:')` filter
- `packages/lan-share/src/lib/lan-share-import.ts` — remove `shared:` prefix when saving secrets
- `packages/lan-share/src/lib/lan-share-resolve.ts` — remove `shared:` prefix from vault lookups
- `packages/electron-defs/src/lib/electron-api.ts` — update the `ISharedSecret` type comment; rename the type if "shared" is now misleading
- `packages/user-interface/src/context/platform-context.tsx` — remove `shared:` filter and type comment
- `packages/user-interface/src/components/receive-secret-dialog.tsx` — remove `shared:` prefix from `saveName`

**Tests to update:**

- `packages/lan-share/src/test/lan-share-import.test.ts`
- `packages/lan-share/src/test/lan-share-resolve.test.ts`
- `packages/vault/src/test/macos-keychain-vault.test.ts`
- `packages/vault/src/test/windows-keychain-vault.test.ts`
- `packages/vault/src/test/linux-keychain-vault.test.ts`

**Migration:** existing vaults will have secrets stored under `shared:` keys. If backwards compatibility is needed, add a one-time migration on startup that renames any `shared:` prefixed vault entries by stripping the prefix.

---

## Edge Cases

**User enters wrong pairing code on receiver**
The sender calls `GET /pairing-code-hash` and gets back a hash that doesn't match. The sender aborts with a clear error message. This consumes one request from the receiver's budget. If the user retries with the correct code, the receiver still has budget remaining and the share proceeds normally.

**Receiver hasn't had a pairing code entered yet**
If the sender discovers the receiver and calls `GET /pairing-code-hash` before the user has entered the code on the receiver, the receiver should return a 425 (Too Early) or simply block until the code is available. Alternatively, the receiver returns an empty/null response and the sender retries with a short backoff. The simplest approach: receiver blocks the `GET /pairing-code-hash` response until the code has been entered (with a timeout).

**No change to UDP broadcast format**
The broadcast message `PSIE_RECV:{port}:{fingerprint}` does not need to change. The pairing code is no longer communicated over the network in the discovery phase.

**Timeout behaviour**
No change — the 60-second timeout still applies to `waitForReceiver`. The `GET /pairing-code-hash` call should have its own short timeout (e.g. 10 seconds) to handle cases where the receiver is slow to accept the pairing code.

---

## Test Plan

- Unit test: sender aborts when `GET /pairing-code-hash` returns a hash that doesn't match the sender's pairing code.
- Unit test: sender proceeds when `GET /pairing-code-hash` returns the correct hash.
- Unit test: receiver rejects `POST /share-payload` when pairing code hash is wrong.
- Unit test: receiver accepts `POST /share-payload` when pairing code hash is correct.
- Integration test: full happy path — sender and receiver on same process, correct pairing code entered, payload received successfully.
- Integration test: fake receiver (no knowledge of pairing code) — sender discovers it, calls `GET /pairing-code-hash`, hash doesn't match, aborts without sending payload.
- Unit test: receiver aborts and returns 429 after exceeding the request budget, regardless of endpoint.
- Unit test: receiver does not abort when request count stays within budget across both endpoints.
