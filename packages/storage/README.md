# Storage

Shared code library for Photosphere storage.

## Setup

Install dependencies for the monorep:

```bash
cd photosphere
bun install
```

Change to the storage package:

```bash
cd packages/storage
```

## Compile

Compile the code:

```bash
bun run compile
```

Compile with live reload:

```bash
bun run compile:watch
```

## Run automated tests

```bash
bun test
```

## Encryption

### New format

New-format files begin with the encryption header:

- 4-byte tag (`PSEN`)
- 4-byte format version (uint32)
- 4-byte encryption type (`A2CB` = AES-256-CBC + RSA)
- 32-byte hash of the public key used to encrypt the file

Followed by the payload:

- Encrypted key
- IV
- Encrypted data

New files are always written using a single write key:

- `encryptionPublicKey` – the public key used when writing new encrypted data

To decrypt a new-format file, the key hash from the header is used to look up the correct private key:

- `decryptionKeyMap[hash(publicKey)]` – private key for new-format files, keyed by the hash stored in the header

### Legacy format

Legacy files have no encryption header — they contain only the payload:

- Encrypted key
- IV
- Encrypted data

To decrypt a legacy file, a default private key is used:

- `decryptionKeyMap["default"]` – private key for legacy files
