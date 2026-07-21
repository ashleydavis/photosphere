# Encrypted fixtures (the crypto shim's oracle)

These files are checked-in fixtures for the mobile crypto shim tests
(`../shims/node-crypto.test.ts`, `../shims/encrypt-stream.test.ts`). They are the **oracle**: they
were produced **once, on Node**, by the real `packages/encryption` code (Node's RSA-OAEP-SHA1 + AES-256-CBC)
via `../generate-encrypted-fixtures.ts`, and the mobile shim test decrypts them to prove the mobile
implementation matches the desktop on-disk format.

**Never regenerate these from the mobile implementation.** Doing so would silently turn the tests into a
tautology (mobile decrypting what mobile encrypted, proving nothing about desktop compatibility). The
generator is run by hand, never by the test suite. Regenerating is a deliberate act reserved for a real
change to the on-disk encrypted format, and it requires a Node run plus a review of why the format
changed.

## Files

- `test-only-do-not-use.public.pem` / `test-only-do-not-use.private.pem`: an RSA-4096 keypair generated
  solely for these tests. **The private key is a real key but a throwaway** — it guards nothing, exists
  only to prove decryption, and must never be reused anywhere.
- `buffer.encrypted.bin` / `buffer.plaintext.txt`: an `encryptBuffer` output and its expected plaintext.
- `stream.encrypted.bin` / `stream.plaintext.txt`: a `createEncryptionStream` output and its expected
  plaintext.

## Scanner note

The repository has no secret scanner or pre-commit hook (`core.hooksPath` is the default, no
`.pre-commit-config`, no CI secret-scan step), so the committed test key does not trip any allowlist. If
one is ever added, add this directory to its allowlist so the throwaway test key is not flagged.
