# Storage

Shared code library for Photosphere storage. Encryption format version and constants (tag, type, key hash length) are defined in this package.

When encryption is enabled, files use a header of the form:

- 4-byte tag (e.g. `PSEN`)
- 4-byte format version (uint32)
- 4-byte encryption type (e.g. `A2CB`)
- 32-byte hash of the public key used to encrypt the file

followed by the legacy payload (encrypted key, IV, ciphertext). Decryption uses a key map:

- `decryptionKeyMap["default"]` – private key for legacy/old-format files (no header)
- `decryptionKeyMap[hash(publicKey)]` – private key for new-format files, keyed by the hash stored in the header

New encrypted files are always written with a single write key:

- `encryptionPublicKey` – the public key used when writing new encrypted data

The combination of `decryptionKeyMap` and `encryptionPublicKey` allows:

- Old-format files to be read with a default key
- New-format files to be read with the correct key (by public-key hash)
- Databases that contain files encrypted with different keys to be decrypted, while always writing new data with a single default/write key.

## Setup

Install dependencies for the monorep:

```bash
cd photosphere
pnpm install
```

Change to the storage package:

```bash
cd packages/storage
```

## Compile

Compile the code:

```bash
pnpm compile
```

Compile with live reload:

```bash
pnpm run compile:watch
```

## Run automated tests

```bash
pnpm test
```
