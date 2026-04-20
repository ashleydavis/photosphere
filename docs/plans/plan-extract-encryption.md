# Plan: Extract `packages/encryption` from `packages/storage`

## Context

The encryption primitives in `packages/storage` (hybrid AES-256-CBC + RSA, key management, streaming encryption) are general-purpose and useful beyond storage. Extracting them into a dedicated `packages/encryption` package makes them available to other packages without pulling in the full storage layer.

---

## Files to move

Move these files from `packages/storage/src/lib/` to `packages/encryption/src/lib/`, updating internal imports:

- `encryption-constants.ts` — format constants (tag, version, type, key hash length)
- `encryption-types.ts` — `IPrivateKeyMap` type
- `encrypt-buffer.ts` — `encryptBuffer()` and `decryptBuffer()` (hybrid AES-256-CBC + RSA)
- `encrypt-stream.ts` — `createEncryptionStream()` and `createDecryptionStream()` (streaming variant)
- `key-utils.ts` — `generateKeyPair()`, `saveKeyPair()`, `loadPrivateKey()`, `loadPublicKey()`, `loadOrGenerateKeyPair()`, `hashPublicKey()`, `exportPublicKeyToPem()`, `loadEncryptionKeysFromPem()`, `loadEncryptionKeys()`, `IKeyPair`, `IEncryptionKeyPem`

**Note:** `read-encryption-header.ts` imports `IStorage` from the storage package, so it must remain in `packages/storage`.

Move these test files from `packages/storage/src/tests/` to `packages/encryption/src/test/`:

- `encrypt-buffer.test.ts`
- `encrypt-stream.test.ts`
- `key-utils.test.ts`
- `encryption-constants.test.ts`

---

## New package setup

Create `packages/encryption/package.json` and `packages/encryption/tsconfig.json` following the same pattern as other packages in the monorepo.

Create `packages/encryption/src/index.ts` re-exporting all modules.

---

## Update `packages/storage`

- Add `encryption` as a workspace dependency in `packages/storage/package.json`
- Update `packages/storage/src/index.ts` to re-export everything from `encryption` so that existing consumers (`apps/cli`, `packages/api`, etc.) continue to work with `import { ... } from "storage"` unchanged
- Update internal imports in `encrypted-storage.ts`, `storage-factory.ts`, and `read-encryption-header.ts` to import from the new `encryption` package instead of relative paths
- Remove the moved files from `packages/storage/src/lib/`

---

## Verification

- `bun run compile` from root must pass
- `bun run test` from root must pass (existing encryption tests now run from `packages/encryption`)
- No import changes needed in consuming packages — `packages/storage` re-exports everything

---

## Files Summary

**New package `packages/encryption`:**
- `src/lib/encryption-constants.ts` (moved from `packages/storage`)
- `src/lib/encryption-types.ts` (moved from `packages/storage`)
- `src/lib/encrypt-buffer.ts` (moved from `packages/storage`)
- `src/lib/encrypt-stream.ts` (moved from `packages/storage`)
- `src/lib/key-utils.ts` (moved from `packages/storage`)
- `src/test/encrypt-buffer.test.ts` (moved from `packages/storage`)
- `src/test/encrypt-stream.test.ts` (moved from `packages/storage`)
- `src/test/key-utils.test.ts` (moved from `packages/storage`)
- `src/test/encryption-constants.test.ts` (moved from `packages/storage`)
- `src/index.ts`
- `package.json`, `tsconfig.json`

**Modified files:**
- `packages/storage/package.json` — add `encryption` workspace dependency
- `packages/storage/src/index.ts` — re-export from `encryption`, remove moved file exports
- `packages/storage/src/lib/encrypted-storage.ts` — import from `encryption` instead of relative paths
- `packages/storage/src/lib/storage-factory.ts` — import from `encryption` instead of relative paths
- `packages/storage/src/lib/read-encryption-header.ts` — import from `encryption` instead of relative paths
