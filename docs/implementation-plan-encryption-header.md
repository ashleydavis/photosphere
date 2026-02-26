# Implementation Plan: Encrypted File Header, Key Map, Encrypt/Decrypt Commands, and Encrypted Smoke Tests

## Commit and quality gates

**Do not commit code unless all of the following pass:**

1. **Code compiles**  
   Run from repo root: `bun run c`  
   Fix any TypeScript/compilation errors before committing.

2. **Unit tests pass**  
   Run from repo root: `bun run test`  
   Fix any failing unit tests before committing.

3. **Smoke tests pass**  
   - After storage/CLI changes: run main smoke tests from `apps/cli`:  
     `./smoke-tests.sh all`  
   - After adding encrypted smoke tests: also run  
     `./smoke-tests-encrypted.sh all`  

Commit only when the codebase compiles and both unit and relevant smoke tests pass. Prefer small, logical commits that each satisfy these gates.

**Preparing commits:** For each commit, implement the changes, run the gates, and have the message and description ready. Do **not** stage files or run `git commit`—the author will stage and commit each one after review.

---

## Reference (shared by commits 2–4)

**New encrypted file layout:**  
`tag (4) + version (4) + type (4) + keyHash (32) + encryptedKey (512) + iv (16) + ciphertext`. Logical header = 44 bytes; payload (512+16+ciphertext) unchanged from current format. Use one endianness for version (e.g. little-endian) and stick to it.

**Detection (decrypt):** If `data.length < 4` → error. First 4 bytes ≠ tag → **old format**: decrypt with legacy layout using `privateKeyMap["default"]`. First 4 bytes = tag: if `data.length < 44` → error; else read version + type; if unsupported version/type → treat as old format (default key) or error; if valid, read 32-byte key hash, look up key in map (e.g. hex string), decrypt payload.

**Key map:** `IPrivateKeyMap` = `Record<string, KeyObject>`. Key `"default"` = private key for old-format files. Other keys = hex-encoded SHA-256 of public key (same as in header). Encryption always uses a single key pair + that key’s public-key hash in the header.

---

## Commits

Each commit is self-contained: implement the “What to do” below, add the tests and README, run the gates, then commit. No need to cross-reference other sections.

---

### [ ] Commit 1: Storage – encryption constants and public key hash

- **Message:** `Add encryption constants and public key hash`
- **Description:** Adds `encryption-constants.ts` (tag, format version, encryption type, key hash length) and `hashPublicKey()` in key-utils so encrypted file headers and key identification have a single source of truth. Constants are exported from storage; `hashPublicKey` exports the key as SPKI and returns a 32-byte SHA-256 hash for use in headers and key maps.

- **Scope**: `packages/storage`
- **What to do**:
  - Add `src/lib/encryption-constants.ts`: 4-byte encryption tag (e.g. `"PSEN"`), uint32 format version (e.g. `1`), 4-byte encryption type (e.g. `"A2CB"`), constant for key hash length (32). Export from `src/index.ts`.
  - In `src/lib/key-utils.ts`: add `hashPublicKey(publicKey: KeyObject): Buffer` — export key as SPKI, return 32-byte SHA-256 hash. Export.
- **Unit tests**: `packages/storage/src/tests/`: constants match expected bytes/lengths; `hashPublicKey` returns 32 bytes and is deterministic for same key.
- **Smoke tests**: `./smoke-tests.sh all` from `apps/cli` (sanity).
- **README**: `packages/storage/README.md` — optional one-liner that encryption format version/constants live here.

---

### [ ] Commit 2: Storage – key map type and encrypt-buffer

- **Message:** `Add key map and new-format encrypt/decrypt for buffers`
- **Description:** Introduces `IPrivateKeyMap` and updates buffer encrypt/decrypt: `encryptBuffer` always writes the new header (tag, version, type, keyHash + payload); `decryptBuffer` takes a key map and supports both legacy files (no header, use `"default"` key) and new-format files (header + key lookup by hash). Keeps decryption backward compatible and prepares for multi-key migration without touching streams or storage yet.

- **Scope**: `packages/storage`
- **What to do**:
  - Define `IPrivateKeyMap` (e.g. in `storage-factory.ts` or `encryption-types.ts`): `Record<string, KeyObject>`, `"default"` reserved for old-format.
  - `encrypt-buffer.ts`: `encryptBuffer(publicKey, data, options?)` — write **new format** (tag, version, type, keyHash from options or from constants + `hashPublicKey(publicKey)`, then 512+16+ciphertext). `decryptBuffer(data, privateKeyMap)` — use **Reference** detection: old format → `privateKeyMap["default"]`; new format → look up by key hash (header 32 bytes → hex string). Error if key missing or data too short.
- **Unit tests**: `packages/storage/src/tests/encrypt-buffer.test.ts`: round-trip new format with key map; decrypt legacy with `"default"`; decrypt new format by hash; error when hash not in map or no default for old.
- **Smoke tests**: `./smoke-tests.sh all` from `apps/cli`.
- **README**: None.

---

### [ ] Commit 3: Storage – encrypt-stream

- **Message:** `Add new-format header and key map support to encrypt/decrypt streams`
- **Description:** Aligns stream encrypt/decrypt with the new format and key map: `createEncryptionStream` pushes the header (tag, version, type, keyHash) then the existing payload; `createDecryptionStream` takes a key map and handles both legacy (no header, default key) and new-format (parse header, look up key, stream decipher) so replication and large-file reads work the same as the buffer API.

- **Scope**: `packages/storage`
- **What to do**:
  - `encrypt-stream.ts`: `createEncryptionStream(publicKey, options?)` — push tag, version, type, keyHash (from options or constants + `hashPublicKey`), then 512+16+ciphertext. `createDecryptionStream(privateKeyMap)` — buffer until 4 bytes, check tag; if no tag → old format (buffer 512+16, use default key, stream decipher); if tag → buffer 44 bytes, parse version/type/keyHash, validate, look up key, buffer to 572 bytes, decipher payload and stream rest.
- **Unit tests**: `packages/storage/src/tests/encrypt-stream.test.ts`: stream round-trip new format; stream decrypt legacy; stream decrypt new format by hash.
- **Smoke tests**: `./smoke-tests.sh all` from `apps/cli`.
- **README**: None.

---

### [ ] Commit 4: Storage – EncryptedStorage, createStorage, loadEncryptionKeys

- **Message:** `Wire EncryptedStorage to key map and new format; extend loadEncryptionKeys`
- **Description:** Wires EncryptedStorage to the key map and new format: reads use the key map (old and new format); writes use a single write key and hash and always emit the new format. When callers pass only a single key pair, createStorage and loadEncryptionKeys build a key map (default + hash entry) so existing single-key usage keeps working and multi-key decryption is available. All encrypted I/O now goes through this layer with backward compatibility.

- **Scope**: `packages/storage` (+ callers of `createStorage` / `loadEncryptionKeys`)
- **What to do**:
  - **EncryptedStorage**: Constructor takes key map (for read) and write key pair + public key hash (for write). `read`/`readStream` use key map (Reference detection). `write`/`writeStream` use write key and hash (new format only). Backward compat: when caller passes only one key pair, treat as key map with that key as both `"default"` and entry keyed by `hashPublicKey(publicKey).toString('hex')`.
  - **storage-factory.ts**: `IStorageOptions` gains `privateKeyMap?`. If only `publicKey`/`privateKey` provided, build key map (default + hash key) and pass to EncryptedStorage; pass same key as write key.
  - **key-utils.ts**: `loadEncryptionKeys` also sets `options.privateKeyMap` (default + hash key) so decryption path has the map.
- **Unit tests**: EncryptedStorage write → new format; read with same key (via map) works; read legacy blob with `"default"` works; createStorage with single key reads old and new format.
- **Smoke tests**: `./smoke-tests.sh all` from `apps/cli`.
- **README**: `packages/storage/README.md` — “Encryption” subsection: new header, backward compat, key map and `"default"`.

---

### [ ] Commit 5: CLI – encrypt command

- **Message:** `Add encrypt command for plain→encrypted, re-encrypt, and old→new format`
- **Description:** Adds `psi encrypt` so users can encrypt a plain DB, re-encrypt with a new key, or convert an old-format encrypted DB to the new format (same key) without manual file work. Uses createStorage for source and dest (with or without keys), copies all asset and metadata files through the right storage layer, writes `.db/encryption.pub` at encrypted destinations, and reuses existing replicate/copy and key resolution.

- **Scope**: `apps/cli`
- **What to do**:
  - Add `src/cmd/encrypt.ts`. **Behaviors:** (1) Plain → encrypted: `--db <plain> --dest <dir> --key <keyfile> [--generate-key]` — source no key, dest with key; copy all files through EncryptedStorage (new format); copy `.db` metadata; write `.db/encryption.pub` at dest. (2) Re-encrypt: `--db <enc> --dest <dir> --key <new-key> [--generate-key] --source-key <old-key>` — source key map (old), dest new key. (3) Old-format → new format (same key): `--key` and `--source-key` same path. Options: `--db`, `--dest`, `--key`, `--generate-key`, `--source-key`, `--yes`. Reuse `resolveKeyPath`, `loadEncryptionKeys`, `createStorage`, replicate/copy logic.
  - Register `encrypt` in `index.ts` with `initContext(encryptCommand)`.
- **Unit tests**: Command test if present; else rely on smoke.
- **Smoke tests**: `./smoke-tests.sh all` from `apps/cli`.
- **README**: `apps/cli/README.md` — document `psi encrypt` (usage + brief: encrypt plain, re-encrypt, or convert old→new format).

---

### [ ] Commit 6: CLI – decrypt command

- **Message:** `Add decrypt command to write encrypted DB to plain storage`
- **Description:** Adds `psi decrypt` to read an encrypted DB (old or new format) and write decrypted content to a plain destination, for backup or migration. Source storage is created with a key map from `--key` (and optional `--source-key`); destination is unencrypted. All files are copied via source read / dest write; metadata is copied but `.db/encryption.pub` is not written at the destination.

- **Scope**: `apps/cli`
- **What to do**:
  - Add `src/cmd/decrypt.ts`: `psi decrypt --db <encrypted> --dest <plain> --key <keyfile> [--yes]`. Source storage with key map (`--key`; optionally `--source-key` for multiple keys); dest unencrypted. Copy all files (read via EncryptedStorage, write plain). Copy metadata; do **not** write `.db/encryption.pub` at dest.
  - Register `decrypt` in `index.ts`.
- **Unit tests**: Same as Commit 5.
- **Smoke tests**: `./smoke-tests.sh all` from `apps/cli`.
- **README**: `apps/cli/README.md` — document `psi decrypt` (usage + brief).

---

### [ ] Commit 7: Encrypted smoke test script

- **Message:** `Add smoke-tests-encrypted.sh with seven independent encryption tests`
- **Description:** Adds `smoke-tests-encrypted.sh` following the main smoke script’s conventions. Seven tests (init-encrypted, replicate-to/from-encrypted, encrypt-plain, encrypt-reencrypt, encrypt-old-to-new-format, decrypt-encrypted) each use their own directory and keys so they are independent and safe to run in any order or alone. Uses the same env, helpers, and invocation pattern as `smoke-tests.sh`; test 6 may use an optional old-format fixture.

- **Scope**: `apps/cli` (+ optional fixture)
- **What to do**:
  - Add `apps/cli/smoke-tests-encrypted.sh`: same conventions as `smoke-tests.sh` (env, helpers, TEST_TABLE, run_test, run_all_tests, main, `--binary`, `--tmp-dir`, reset, setup, all, by name/index). **Seven tests**, each with its own dir under `TEST_TMP_DIR` and own keys: (1) **init-encrypted** — init with `--key` + `--generate-key`, assert `.db`, `.db/files.dat`, `.db/encryption.pub`; (2) **replicate-to-encrypted** — plain DB + asset, replicate with `--dest-key` + `--generate-key`, assert dest encrypted and verify with key; (3) **replicate-from-encrypted** — encrypted DB + asset, replicate to plain dest, assert dest unencrypted and verify; (4) **encrypt-plain** — plain DB + assets, `psi encrypt` to dest, assert dest encrypted and verify; (5) **encrypt-reencrypt** — encrypted with key1, `psi encrypt --key key2 --source-key key1`, assert dest works only with key2; (6) **encrypt-old-to-new-format** — old-format DB (fixture or create before header change), `psi encrypt` same key to dest, assert dest has 4-byte tag and verify; (7) **decrypt-encrypted** — encrypted DB + assets, `psi decrypt` to plain, assert dest unencrypted and verify. For test 6, prefer a committed old-format fixture (e.g. `apps/cli/test/fixtures/old-format-encrypted/`).
- **Unit tests**: N/A.
- **Smoke tests**: `./smoke-tests-encrypted.sh all` and `./smoke-tests.sh all` from `apps/cli`.
- **README**: `apps/cli/README.md` — “Encrypted database smoke tests”: describe `smoke-tests-encrypted.sh`, how to run (all, by name, reset, setup), independence (own dirs/keys).

---

### [ ] Commit 8: Docs and README polish

- **Message:** `Add encrypt/decrypt and encrypted smoke tests to READMEs`
- **Description:** Updates root or CLAUDE docs with brief references to `encrypt`/`decrypt` and the encrypted smoke tests where relevant, and brings packages/storage and apps/cli READMEs in line with the encryption format, commands, and how to run the encrypted test script so the docs match the implementation.

- **Scope**: repo docs
- **What to do**: Root `README.md` or `CLAUDE.md` — add one-line refs to `encrypt`/`decrypt` and encrypted smoke tests if those topics exist. Ensure `packages/storage/README.md` and `apps/cli/README.md` match Commits 1–7.
- **Unit tests**: N/A.
- **Smoke tests**: `./smoke-tests.sh all` and `./smoke-tests-encrypted.sh all` from `apps/cli`.
- **README**: Final pass on any README touched by this feature.

---

**After each commit:** Run `bun run c`, `bun run test`, and the smoke tests listed for that commit; only then commit.
