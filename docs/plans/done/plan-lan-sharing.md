# Plan: LAN Sharing of Database Configs and Secrets

## Open Issues

- [x] **RSA payload size limit**: No longer applicable — the plan now uses HTTPS (TLS) for transport encryption instead of explicit hybrid encryption.
- [x] **PIN hash is trivially reversible**: Resolved — HTTPS encrypts all traffic including the pin hash, so a passive sniffer cannot capture it.
- [x] **`lan-share` will break the browser build**: Resolved — `packages/user-interface` does not need to depend on `lan-share`. The frontend communicates with the Electron main process via IPC using opaque `unknown` payloads. Only `apps/cli` and `apps/desktop` (both Node.js environments) depend on `lan-share`. Form state types for the UI dialogs are defined locally in the dialog components.
- [x] **`resolve`/`import` helpers create a dependency inversion**: Resolved — vault and database config APIs live in shared packages (`packages/vault`, `packages/node-utils`), not in app-level code. `packages/lan-share` depending on them is a normal package-to-package dependency, not an inversion.
- [x] **No handling of name/path collisions on import**: Resolved — the edit flow on the receive side validates the chosen name/path against existing entries. If a database with the same name or path (or a secret with the same name) already exists, the user is shown a conflict warning and must choose a different name before saving.
- [x] **Multiple simultaneous receivers**: Resolved — docs and UI hints instruct the user to only run one receiver at a time. If two receivers are running, the sender connects to whichever it discovers first; the pairing code check prevents accidental sends to the wrong device.

---

## Context

We need to share database configurations (with resolved secrets) and standalone secrets between devices over the LAN. This works in both the CLI and Electron app. One device acts as sender, the other as receiver. The sender can view and modify details before sending, and the receiver can view and modify details before saving.

The `qr-proto` branch has a working prototype for the Electron app using UDP + HTTP. We'll extract and improve this networking logic into a shared package with a safer architecture described below.

---

## Security Architecture

Credentials are transferred over the LAN using HTTPS with a self-signed TLS certificate generated at runtime. This encrypts all traffic so that no other device on the network can read it, even if it intercepts the packets. A 4-digit pairing code prevents a rogue device from impersonating a legitimate sender or receiver. The TLS certificate fingerprint is included in the UDP broadcast so the sender can pin the certificate and reject MITM attempts.

### Flow

1. **Receiver starts** — generates a random 4-digit pairing code, a self-signed TLS certificate, and starts an HTTPS server on a random port. It broadcasts `PSIE_RECV:{port}:{certFingerprint}` via UDP to `255.255.255.255:54321` every 1s so that senders can discover it. The pairing code is displayed to the user.
2. **Sender discovers receiver** — listens on UDP port 54321 for `PSIE_RECV:{port}:{certFingerprint}` broadcasts. When one arrives, it knows the receiver's IP address, port, and expected certificate fingerprint.
3. **Sender sends payload** — the sender obtains the pairing code from the user (who reads it from the receiver's screen). It connects over HTTPS (pinning the certificate fingerprint from the broadcast) and POSTs the JSON payload along with the pin hash (`{ pinHash: SHA256(code), payload: ... }`) to `POST /share-payload`. TLS encrypts the traffic on the wire.
4. **Receiver verifies and accepts** — computes `SHA256(code)` from its own stored code and compares against the submitted hash. On match, it accepts the payload and presents it to the user for review. On mismatch, it returns 403. After 3 failed attempts the receiver aborts the share entirely.

### Why this is safe

- **Transport encryption**: All HTTP traffic is encrypted by TLS. Even if another device on the LAN captures the packets, it cannot read the contents — including the pin hash.
- **Certificate pinning**: The TLS certificate fingerprint is broadcast via UDP, so the sender verifies it is talking to the correct receiver. A MITM attacker cannot substitute their own certificate without the sender rejecting the connection.
- **Pin verification**: The receiver checks the pin hash before accepting the payload. A rogue sender that doesn't know the code cannot send a payload the receiver would accept.
- **Rate limiting**: 3 failed pin attempts abort the share, making brute-force of the 4-digit code impractical in practice.

---

## User Stories

### CLI — Send a database
- User runs `psi dbs send [name]`
- If name is omitted, a `select` prompt lists all configured databases to pick from
- Hint: "Run `psi dbs receive` on another device to receive this database."
- Security warning: "This will share sensitive credentials over your local network. Only use this on a trusted network." User confirms to proceed.
- Database config is displayed with linked secrets resolved from the vault
- User confirms (and optionally edits) fields before sending — name, description, path, and for each secret a confirm whether to include it
- CLI searches for a receiver on the LAN (60s timeout, cancellable with Ctrl+C)
- When a receiver is found, user is prompted to enter the 4-digit pairing code displayed on the receiver
- Payload is encrypted and sent to the receiver; CLI prints success

### CLI — Receive a database
- User runs `psi dbs receive`
- Hint: "Run `psi dbs send` on another device to send a database."
- A 4-digit pairing code is generated and displayed
- CLI starts an HTTP server and broadcasts availability on the LAN (60s timeout, cancellable with Ctrl+C)
- When a sender delivers the payload, the config and secret labels are displayed
- User can edit name, description, path and choose which secrets to import
- Database entry and secrets are saved locally

### CLI — Send a secret
- User runs `psi secrets send [name]`
- If name is omitted, a `select` prompt lists all vault secrets to pick from
- Hint: "Run `psi secrets receive` on another device to receive this secret."
- Security warning: "This will share sensitive credentials over your local network. Only use this on a trusted network." User confirms to proceed.
- Secret is displayed; user confirms (and optionally edits) fields before sending
- CLI searches for a receiver on the LAN (60s timeout, cancellable with Ctrl+C)
- When a receiver is found, user enters the 4-digit pairing code shown on the receiver
- Payload is encrypted and sent; CLI prints success

### CLI — Receive a secret
- User runs `psi secrets receive`
- Hint: "Run `psi secrets send` on another device to send a secret."
- A 4-digit pairing code is generated and displayed
- CLI starts an HTTP server and broadcasts availability on the LAN (60s timeout, cancellable with Ctrl+C)
- When a sender delivers the payload, its type and label are displayed
- User can edit the name to save it as; secret is saved locally

### Desktop app — Send a database
- User clicks "Share" on a database entry in the databases page
- Hint in dialog: "Click Receive Database on another device to receive this database."
- Security warning is shown in the dialog
- User can review and edit the database config and choose which secrets to include
- Dialog searches for a receiver on the LAN (60s timeout, cancellable via Cancel button)
- When a receiver is found, user enters the 4-digit pairing code shown on the receiver
- Payload is encrypted and sent; dialog shows success

### Desktop app — Receive a database
- User clicks "Receive Database" on the databases page
- Hint in dialog: "Click Share on a database on another device to send it here."
- A 4-digit pairing code is generated and displayed prominently in the dialog
- Dialog waits for a sender on the LAN (60s timeout, cancellable via Cancel button)
- When a sender delivers the payload, editable form fields are displayed (name, description, path, secrets)
- User reviews/edits and clicks "Save" to import

### Desktop app — Send a secret
- User clicks "Share" on a secret entry in the secrets page
- Hint in dialog: "Click Receive Secret on another device to receive this secret."
- Security warning is shown; user can review/edit before sending
- Dialog searches for a receiver on the LAN (60s timeout, cancellable via Cancel button)
- When a receiver is found, user enters the 4-digit pairing code
- Payload is encrypted and sent; dialog shows success

### Desktop app — Receive a secret
- User clicks "Receive Secret" on the secrets page
- Hint in dialog: "Click Share on a secret on another device to send it here."
- A 4-digit pairing code is generated and displayed
- Dialog waits for a sender on the LAN (60s timeout, cancellable via Cancel button)
- When a sender delivers the payload, its type and label are displayed in editable fields
- User reviews/edits and clicks "Save" to import

---

## Phase 1 — Share Payload Types

Create a new `packages/lan-share` package. Add it as a workspace dependency to `apps/cli` and `apps/desktop` (both Node.js environments). `packages/user-interface` does not depend on `lan-share` — the frontend communicates via IPC using opaque `unknown` payloads, and form state types are defined locally in dialog components. The Electron main process does not need to know about the payload types — IPC handlers pass payloads as opaque JSON (`unknown`).

Add new interfaces to `packages/lan-share/src/lib/lan-share-types.ts`:

```typescript
// Resolved S3 credentials included in a share payload.
interface IShareS3Credentials {
    label: string;
    region: string;
    accessKeyId: string;
    secretAccessKey: string;
    endpoint?: string;
}

// Resolved encryption key pair included in a share payload.
interface IShareEncryptionKey {
    label: string;
    privateKeyPem: string;
    publicKeyPem: string;
}

// Resolved geocoding API key included in a share payload.
interface IShareGeocodingKey {
    label: string;
    apiKey: string;
}

// Share payload for a full database configuration with all resolved secrets.
interface IDatabaseSharePayload {
    type: "database";
    name: string;
    description: string;
    path: string;
    origin?: string;
    s3Credentials?: IShareS3Credentials;
    encryptionKey?: IShareEncryptionKey;
    geocodingKey?: IShareGeocodingKey;
}

// Share payload for a single standalone secret.
interface ISecretSharePayload {
    type: "secret";
    secretType: "s3-credentials" | "encryption-key" | "api-key";
    value: string; // JSON string, same format as vault value field
}
```

The networking classes (`LanShareSender`/`LanShareReceiver`) work with `unknown` — callers cast to the appropriate type based on context.

---

## Phase 2 — Shared Networking Module

Add four more files to `packages/lan-share/src/lib/`:

### `lan-share-receiver.ts`

The receiver hosts the HTTPS server and broadcasts its availability. It generates a self-signed TLS certificate and a 4-digit pairing code.

Class `LanShareReceiver`:
- `constructor(timeoutMs: number = 60000)`
- `start(): Promise<IReceiverInfo>` — generates a 4-digit code and a self-signed TLS certificate, creates HTTPS server on random port with a single endpoint (`POST /share-payload`), starts UDP broadcast of `PSIE_RECV:{port}:{certFingerprint}` to `255.255.255.255:54321` every 1s. Returns `{ code: string }` so the caller can display the code.
  - `POST /share-payload` — accepts `{ pinHash, payload }`. Verifies the pin hash matches, returns 403 on mismatch (aborts after 3 failed attempts). On match, accepts the payload.
- `receive(): Promise<unknown>` — waits for a valid POST to arrive and returns the payload, or null on timeout.
- `cancel(): void` — closes socket, HTTPS server, resolves with null

### `lan-share-sender.ts`

The sender listens for receiver broadcasts, verifies the pin, and POSTs the payload over HTTPS.

Class `LanShareSender`:
- `constructor(payload: unknown)`
- `waitForReceiver(timeoutMs: number = 60000): Promise<IReceiverEndpoint | null>` — listens on UDP port 54321 for `PSIE_RECV:{port}:{certFingerprint}` messages, returns `{ address: string, port: number, certFingerprint: string }` or null on timeout
- `send(endpoint: IReceiverEndpoint, code: string): Promise<boolean>` — connects over HTTPS (pinning the certificate fingerprint from discovery), POSTs `{ pinHash: SHA256(code), payload }` to `/share-payload`. Returns false on 403 (wrong pin), true on success.
- `cancel(): void` — closes UDP socket

### `lan-share-resolve.ts`

Helper functions to build share payloads from existing data:

- `resolveDatabaseSharePayload(entry: IDatabaseEntry): Promise<IDatabaseSharePayload>` — reads vault to resolve `s3CredentialId`, `encryptionKeyId`, `geocodingKeyId` into full credential objects
- `resolveSecretSharePayload(secretName: string): Promise<ISecretSharePayload>` — reads vault entry and wraps it

### `lan-share-import.ts`

Helper functions to import received payloads:

- `importDatabasePayload(payload: IDatabaseSharePayload): Promise<IDatabaseEntry>` — creates vault entries for each included secret with fresh `shared:{random8}` IDs, returns the `IDatabaseEntry` (caller saves it via `addDatabaseEntry`)
- `importSecretPayload(payload: ISecretSharePayload, secretName: string): Promise<void>` — creates a vault entry with the given name

### Export

Create `packages/lan-share/src/index.ts` to export all modules.

---

## Phase 3 — CLI Commands

### `psi dbs send [name]` and `psi dbs receive`

Add `send` and `receive` sub-commands to the existing `dbsCommand()` in `apps/cli/src/cmd/dbs.ts`:

**`psi dbs send [name]`:**
1. If name is omitted, show a `select` prompt listing all configured databases
2. Print hint: "Run `psi dbs receive` on another device to receive this database."
3. Security warning (clack `note` in yellow) + `confirm` prompt
4. Look up database by name (reuse `findDatabaseByName`)
5. Call `resolveDatabaseSharePayload(entry)` to build payload
6. Display resolved payload fields and enter edit flow using clack `text` prompts (pre-filled with resolved values) — name, description, path, and for each secret show label and `confirm` whether to include it
7. Create `LanShareSender`, call `waitForReceiver(60000)`
8. Show spinner: "Searching for receiver on the LAN... (Ctrl+C to cancel)"
9. When receiver found, prompt user to enter the 4-digit pairing code shown on the receiver
10. Call `sender.send(endpoint, code)` — if rejected (403), prompt to retry
11. On success: print success. On timeout: print "No receiver found." On Ctrl+C: call `cancel()`

**`psi dbs receive`:**
1. Print hint: "Run `psi dbs send` on another device to send a database."
2. Create `LanShareReceiver`, call `start()` — display the returned 4-digit code
3. Show spinner: "Waiting for sender... Code: XXXX (Ctrl+C to cancel)"
4. Call `receiver.receive()`
5. If null (timeout): print "No sender connected."
6. If received: display fields (name, path, secret labels), then enter edit flow using clack `text` prompts (pre-filled with received values) — following the pattern in `dbsEdit`. For each secret present, show `confirm`: "Import S3 credentials (label)?"
7. Call `importDatabasePayload` with modified payload
8. Call `addDatabaseEntry` with the result
9. Print success. On Ctrl+C: call `cancel()`

### `psi secrets send [name]` and `psi secrets receive`

Add `send` and `receive` sub-commands to the existing `secretsCommand()` in `apps/cli/src/cmd/secrets.ts`:

**`psi secrets send [name]`:**
1. If name is omitted, show a `select` prompt listing all vault secrets
2. Print hint: "Run `psi secrets receive` on another device to receive this secret."
3. Security warning + confirm
4. Look up secret by name from vault
5. Call `resolveSecretSharePayload(name)` to build payload
6. Display secret type and label, allow editing fields before sending
7. Create `LanShareSender`, call `waitForReceiver(60000)`
8. Show spinner: "Searching for receiver on the LAN... (Ctrl+C to cancel)"
9. When receiver found, prompt for 4-digit pairing code
10. Call `sender.send(endpoint, code)` — if rejected (403), prompt to retry
11. On success: print success. On timeout: print "No receiver found." On Ctrl+C: call `cancel()`

**`psi secrets receive`:**
1. Print hint: "Run `psi secrets send` on another device to send a secret."
2. Create `LanShareReceiver`, call `start()` — display 4-digit code
3. Show spinner: "Waiting for sender... Code: XXXX (Ctrl+C to cancel)"
4. Call `receiver.receive()`
5. If null (timeout): print "No sender connected."
6. If received: show secret type and label, prompt for name to save as
7. Call `importSecretPayload(payload, name)`
8. Print success. On Ctrl+C: call `cancel()`

---

## Phase 4 — Electron Integration

### `apps/desktop/src/main.ts`

Replace prototype's inline networking with shared classes. Module-level state: `let activeSender: LanShareSender | null` and `let activeReceiver: LanShareReceiver | null`.

IPC handlers pass payloads as opaque `unknown` — the main process doesn't import share payload types:
- `start-share-receive` — creates `LanShareReceiver`, calls `start()`, returns `{ code: string }`
- `wait-share-receive` — calls `receiver.receive()`, returns `unknown | null`
- `cancel-share-receive` — calls `receiver.cancel()`
- `wait-for-receiver` — creates `LanShareSender` with payload, calls `waitForReceiver()`, returns endpoint or null
- `send-to-receiver` — calls `sender.send(endpoint, code)`, returns `boolean`
- `cancel-share-send` — calls `sender.cancel()`
- `import-share-payload` — takes `unknown`, passes to `importDatabasePayload` or `importSecretPayload` in `lan-share`, calls `addDatabaseEntry` for database payloads

### `packages/electron-defs/src/lib/electron-api.ts`

Update `IElectronAPI` with new method signatures (all payloads opaque `unknown`):
- `startShareReceive(): Promise<{ code: string }>`
- `waitShareReceive(): Promise<unknown>`
- `cancelShareReceive(): Promise<void>`
- `waitForReceiver(payload: unknown): Promise<unknown>`
- `sendToReceiver(endpoint: unknown, code: string): Promise<boolean>`
- `cancelShareSend(): Promise<void>`
- `importSharePayload(payload: unknown): Promise<void>`

### `apps/desktop/src/preload.ts`

Wire new IPC channel names.

### `packages/user-interface/src/context/platform-context.tsx`

Update `IPlatformContext` with new share methods. Remove prototype's `IDatabaseShareConfig` (replaced by types from `lan-share`).

### Frontend UI

Update `packages/user-interface/src/components/share-database-dialog.tsx`:
- Show security warning and editable form fields for the database config
- Call `platform.waitForReceiver(payload)` to find a receiver
- Prompt user for the 4-digit code, call `platform.sendToReceiver(endpoint, code)`
- Show success or retry on rejection

Update `packages/user-interface/src/components/receive-database-dialog.tsx`:
- Call `platform.startShareReceive()` to get the pairing code, display it prominently
- Call `platform.waitShareReceive()` to wait for the payload
- Display editable form fields (name, description, path, secrets)
- On "Save", call `platform.importSharePayload(editedPayload)`

Add similar dialogs for secret sharing, or extend existing dialogs to handle both payload types.

Update `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` to wire new API methods.

---

## Phase 5 — Security Warning

**CLI:** clack `note()` with yellow styling before every send operation, followed by `confirm` prompt.

**Electron:** Yellow `Alert` component at the top of send dialogs: "Credentials will be shared over your local network. Only use this on a trusted network."

---

## Files Summary

**New package `packages/lan-share`:**
- `src/lib/lan-share-types.ts`
- `src/lib/lan-share-sender.ts`
- `src/lib/lan-share-receiver.ts`
- `src/lib/lan-share-resolve.ts`
- `src/lib/lan-share-import.ts`
- `src/test/lan-share-sender.test.ts`
- `src/test/lan-share-receiver.test.ts`
- `src/test/lan-share-resolve.test.ts`
- `src/test/lan-share-import.test.ts`
- `src/index.ts`
- `package.json`, `tsconfig.json`

**New file:**
- `apps/cli/smoke-tests-lan-share.sh`

**Documentation updates:**
- `../photosphere.wiki/Sharing-Credentials.md` — new wiki page covering how LAN sharing works, the security architecture (pairing code, hybrid AES+RSA encryption, pin verification), and usage instructions for both CLI and desktop app (send/receive databases and secrets)
- `../photosphere.wiki/Command-Reference.md` — add `psi dbs send/receive` and `psi secrets send/receive` command docs
- `../photosphere.wiki/Managing-Databases.md` — add a "Sharing" section that links to the new Sharing-Credentials page
- `../photosphere.wiki/Managing-Secrets.md` — add a "Sharing" section that links to the new Sharing-Credentials page
- `apps/cli/src/examples.ts` — add examples for `psi dbs send/receive` and `psi secrets send/receive`

**Modified files:**
- `packages/electron-defs/src/lib/electron-api.ts` — IElectronAPI updates
- `apps/cli/src/cmd/dbs.ts` — add `send` and `receive` sub-commands
- `apps/cli/src/cmd/secrets.ts` — add `send` and `receive` sub-commands
- `apps/desktop/src/main.ts` — replace prototype networking with shared classes
- `apps/desktop/src/preload.ts` — wire new IPC channels
- `packages/user-interface/src/context/platform-context.tsx` — update IPlatformContext
- `packages/user-interface/src/components/share-database-dialog.tsx` — use real data
- `packages/user-interface/src/components/receive-database-dialog.tsx` — add edit form
- `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` — wire new methods

---

## Testing

- Write unit tests for all new code in `packages/lan-share/src/test/`
- Create `apps/cli/smoke-tests-lan-share.sh` — runs a sender and receiver in parallel to verify end-to-end database and secret sharing via the CLI
- Compile check: `bun run compile` from root
- Existing smoke tests: `apps/cli/smoke-tests.sh` should still pass
