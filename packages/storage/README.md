# Storage

Shared code library for Photosphere storage. Encryption format version and constants (tag, type, key hash length) are defined in this package.

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
