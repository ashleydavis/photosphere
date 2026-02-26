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

**Keep it simple:** Avoid over-engineering. Only add options, abstractions, or extra types when they are clearly required by the current feature or tests; prefer the simplest design that satisfies the requirements.

**New code:** Any new functions added as part of this plan should have a brief intent-level comment (explaining what the function does and its contract) and at least one unit test that exercises the normal path and any important edge cases.

---

## Reference (shared by commits 2–4)

**Default key and write key:** The first private key provided (first in the comma-separated list) is the default key and the one used to write encrypted files. It must always match the public key stored in the database (e.g. `.db/encryption.pub`), or the command must return an error.

**Setting and changing the default key:** Initial creation of an encrypted database via `init`, `replicate`, or `encrypt` sets the default private key by storing its public key in the database. After the encrypted database exists, the only way to change the default key is to run `encrypt` again (to set a new default key) or `decrypt` (which removes encryption and the default key).

**New encrypted file layout:**  
`tag (4) + version (4) + type (4) + keyHash (32) + encryptedKey (512) + iv (16) + ciphertext`. Logical header = 44 bytes; payload (512+16+ciphertext) unchanged from current format. Use one endianness for version (e.g. little-endian) and stick to it.

**Detection (decrypt):** If `data.length < 4` → error. First 4 bytes ≠ tag → **old format**: decrypt with legacy layout using `privateKeyMap["default"]`. First 4 bytes = tag: if `data.length < 44` → error; else read version + type; if unsupported version/type → treat as old format (default key) or error; if valid, read 32-byte key hash, look up key in map (e.g. hex string), decrypt payload.

**Key map:** `IPrivateKeyMap` allows decrypting files encrypted with different keys (header key hash → map entry). **Key arguments:** Commands that take `--key`, `--dest-key`, or `--source-key` accept a **comma-separated list** of key paths; these are loaded and merged into one `privateKeyMap`. The first key is used as the write key when encrypting. **Key map (cont.):** `IPrivateKeyMap` = `Record<string, KeyObject>`. Key `"default"` = private key for old-format files. Other keys = hex-encoded SHA-256 of public key (same as in header). Encryption always uses a single key pair + that key’s public-key hash in the header.

**Key arguments:** Every CLI command that takes `--key`, `--dest-key`, or `--source-key` must accept a **comma-separated list** of key file paths. These paths are loaded and merged into a single `privateKeyMap` so that databases containing files encrypted with different keys can be decrypted. The first key in the list is used as the write key when encryption is needed (e.g. for init, replicate dest, encrypt dest).

---

## Commits

Each commit is self-contained: implement the “What to do” below, add the tests and README, run the gates, then commit. No need to cross-reference other sections.

---

### [x] Commit 1: Storage – encryption constants and public key hash

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

### [x] Commit 2: Storage – key map type and encrypt-buffer

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

### [x] Commit 3: Storage – encrypt-stream

- **Message:** `Add new-format header and key map support to encrypt/decrypt streams`
- **Description:** Aligns stream encrypt/decrypt with the new format and key map: `createEncryptionStream` pushes the header (tag, version, type, keyHash) then the existing payload; `createDecryptionStream` takes a key map and handles both legacy (no header, default key) and new-format (parse header, look up key, stream decipher) so replication and large-file reads work the same as the buffer API.

- **Scope**: `packages/storage`
- **What to do**:
  - `encrypt-stream.ts`: `createEncryptionStream(publicKey, options?)` — push tag, version, type, keyHash (from options or constants + `hashPublicKey`), then 512+16+ciphertext. `createDecryptionStream(privateKeyMap)` — buffer until 4 bytes, check tag; if no tag → old format (buffer 512+16, use default key, stream decipher); if tag → buffer 44 bytes, parse version/type/keyHash, validate, look up key, buffer to 572 bytes, decipher payload and stream rest.
- **Unit tests**: `packages/storage/src/tests/encrypt-stream.test.ts`: stream round-trip new format; stream decrypt legacy; stream decrypt new format by hash.
- **Smoke tests**: `./smoke-tests.sh all` from `apps/cli`.
- **README**: None.

---

### [x] Commit 4: Storage – EncryptedStorage, createStorage, loadEncryptionKeys

- **Message:** `Wire EncryptedStorage to key map and new format; extend loadEncryptionKeys`
- **Description:** Wires EncryptedStorage to the key map and new format: reads use the key map (old and new format); writes use a single write key and hash and always emit the new format. `loadEncryptionKeys` now takes an array of key paths and builds a key map for all of them: the first key becomes the default (registered under `"default"` and used for writes) and all keys are also registered under the hash of their public key. When callers pass only a single key path, createStorage and loadEncryptionKeys still build the simple default+hash map so existing single-key usage keeps working. All encrypted I/O now goes through this layer with backward compatibility.

- **Scope**: `packages/storage` (+ callers of `createStorage` / `loadEncryptionKeys`)
- **What to do**:
  - **EncryptedStorage**: Constructor takes a key map (for read) and a single write key (public key) for new writes. `read`/`readStream` use the key map (Reference detection). `write`/`writeStream` always use the write key and emit the new format only. Backward compat: when caller passes only one key pair, treat as a key map with that key as both `"default"` and entry keyed by `hashPublicKey(publicKey).toString('hex')`.
  - **storage-factory.ts** and **IStorageOptions**: Remove `publicKey` and `privateKey` from the interface. Rename/add so that (1) the map is `decryptionKeyMap` (decryption only; type remains e.g. `IPrivateKeyMap`); (2) the key used for writing encrypted data is `encryptionPublicKey`. The write private key is taken from `decryptionKeyMap["default"]`, so no separate private key field is needed. `loadEncryptionKeys` returns options with `decryptionKeyMap` and `encryptionPublicKey` (derived from the first key). When building storage, if only a single key pair is provided by a caller, build a single-key decryption map (default + hash entry) and set that key as the encryption public key.
  - **key-utils.ts**: Change `loadEncryptionKeys` to accept an array of key paths (`keyPaths: string[]`; no need for undefined—callers pass an array, possibly empty). For each path, load or generate the key pair; register each private key in the map under the hash of its public key; register the first private key as `"default"` and as the write key. Return `options` with `decryptionKeyMap` (all keys, first under `"default"`) and `encryptionPublicKey` (the first key’s public key for writes).
  - **Comma-separated key paths (all commands):** In this commit, add support for comma-separated key paths for every command that supports `--key`, `--dest-key`, or `--source-key`. In `apps/cli` (and any API workers that take key paths), parse each of these option values as a comma-separated list, split into an array, and pass that array to `loadEncryptionKeys`. Update call sites in:
    - **Shared database loading/creation (affects many commands):** `loadDatabase` and `createDatabase` in `apps/cli/src/lib/init-cmd.ts`, which are used by commands such as `add`, `check`, `export`, `find-orphans`, `list`, `remove`, `remove-orphans`, `summary`, `verify`, `origin`, `set-origin`, `compare` (source side), and the debug subcommands that take `--key`.
    - **Replication/sync/upgrade paths:** `replicate` (`apps/cli/src/cmd/replicate.ts`, `--dest-key`), `sync` (`apps/cli/src/cmd/sync.ts`, `--dest-key`), and `upgrade` (`apps/cli/src/cmd/upgrade.ts`, `--key`).
    - **Hashing/low-level commands:** `hash` (`apps/cli/src/cmd/hash.ts`, `--key`), `hash-cache`, `root-hash`, `database-id`, and any other commands in `apps/cli/index.ts` that expose `--key` / `--dest-key` / `--source-key`.
    - **Workers that receive key paths via `IStorageDescriptor`:** `check.worker.ts`, `import.worker.ts`, and `verify.worker.ts` under `packages/api/src/lib/`, which currently call `loadEncryptionKeys(storageDescriptor.encryptionKeyPath, ...)` and should instead pass an array of key paths (typically a single-element array).
  - The goal is that, after this commit, every CLI command and worker that accepts an encryption key option can take a single key path or a comma-separated list, and all of them ultimately flow through `loadEncryptionKeys(keyPaths: string[])`.
- **Unit tests**: EncryptedStorage write → new format; read with same key (via map) works; read legacy blob with `"default"` works; createStorage with single key reads old and new format.
- **Smoke tests**: `./smoke-tests.sh all` from `apps/cli`.
- **README**: `packages/storage/README.md` — “Encryption” subsection: new header, backward compat, key map and `"default"`.

---

### [ ] Commit 5: CLI – encrypt command

- **Message:** `Add encrypt command for plain→encrypted, re-encrypt, and old→new format`
- **Description:** Adds `psi encrypt` so users can encrypt a plain DB, re-encrypt with a new key, or convert an old-format encrypted DB to the new format (same key) without manual file work. Uses createStorage for source and dest (with or without keys), copies all asset and metadata files through the right storage layer, writes `.db/encryption.pub` at encrypted destinations, and reuses existing replicate/copy and key resolution.

- **Scope**: `apps/cli`
- **What to do**:
  - Add `src/cmd/encrypt.ts`. **Behaviors:** (1) Plain → encrypted: `--db <plain> --dest <dir> --key <keyfile[,keyfile2,...]> [--generate-key]` — source no key, dest with one or more keys; parse the comma-separated list into an array and call `loadEncryptionKeys` so the first key becomes default/write key and all keys populate the key map; copy all files through EncryptedStorage (new format); copy `.db` metadata; write `.db/encryption.pub` at dest. (2) Re-encrypt: `--db <enc> --dest <dir> --key <new-key[,new-key2,...]> [--generate-key] --source-key <old-key[,old-key2,...]>` — build separate key maps for source and dest from their respective lists; source map may contain multiple old keys, dest uses the first new key as default/write key. (3) Old-format → new format (same key): `--key` and `--source-key` lists can both include the same path as their first element so that the same default key is used for reading and writing. Options: `--db`, `--dest`, `--key`, `--generate-key`, `--source-key`, `--yes`. Reuse `resolveKeyPath`, `loadEncryptionKeys`, `createStorage`, replicate/copy logic.
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
  - Add `src/cmd/decrypt.ts`: `psi decrypt --db <encrypted> --dest <plain> --key <keyfile[,keyfile2,...]> [--source-key <keyfile[,keyfile2,...]>] [--yes]`. Source storage is created with a key map from the comma-separated lists (merged into a single `privateKeyMap` where the first key is treated as default for old-format files); destination is unencrypted. Copy all files (read via EncryptedStorage, write plain). Copy metadata; do **not** write `.db/encryption.pub` at dest.
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
  - Add `apps/cli/smoke-tests-encrypted.sh`: same conventions as `smoke-tests.sh` (env, helpers, TEST_TABLE, run_test, run_all_tests, main, `--binary`, `--tmp-dir`, reset, setup, all, by name/index). **Seven tests**, each with its own dir under `TEST_TMP_DIR` and own keys: (1) **init-encrypted** — init with `--key` + `--generate-key`, assert `.db`, `.db/files.dat`, `.db/encryption.pub`; (2) **replicate-to-encrypted** — plain DB + asset, replicate with `--dest-key` + `--generate-key`, assert dest encrypted and verify with key; (3) **replicate-from-encrypted** — encrypted DB + asset, replicate to plain dest, assert dest unencrypted and verify; (4) **encrypt-plain** — plain DB + assets, `psi encrypt` to dest, assert dest encrypted and verify; (5) **encrypt-reencrypt** — encrypted with key1, `psi encrypt --key key2 --source-key key1`, assert dest works only with key2; (6) **encrypt-old-to-new-format** — old-format DB (fixture or create before header change), `psi encrypt` same key to dest, assert dest has 4-byte tag and verify; (7) **decrypt-encrypted** — encrypted DB + assets, `psi decrypt` to plain, assert dest unencrypted and verify. Also add six additional tests: (8) **add-encrypted-file** — add a file to an encrypted database and assert the stored file is encrypted; (9) **export-encrypted-file** — export a file from an encrypted database and assert the exported file is decrypted/plain; (10) **verify-encrypted-db** — verify an encrypted database containing one encrypted file; (11) **delete-encrypted-file** — delete a file from an encrypted database and verify it no longer exists and verification still passes; (12) **list-encrypted-files** — list files in an encrypted database and verify the listing works and shows the added asset; (13) **replicate-decrypted-from-encrypted** — replicate from an encrypted database to a plain destination and verify the destination database is decrypted/plain and passes verification; (14) **export-with-multiple-keys** — start from an encrypted database containing two encrypted files, each encrypted with a different key, and verify that exporting both assets with their respective keys produces correctly decrypted/plain files.
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
