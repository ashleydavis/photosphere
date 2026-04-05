# Plan: Lazy-Pull Missing Assets from Origin Database

## Context

Photosphere supports "partial" database replication where a local copy contains only metadata
structure but not the actual asset/shard data. Since the most recent optimization (commit
8d8a709c), partial replication copies only:

- `.db/files.dat` — merkle tree of all files (references all files, including unfetched ones)
- `.db/bson/*.dat` files — collection merkle trees + sort index `tree.dat`

What is **not** copied in partial mode:
- Shard files: `.db/bson/collections/{collection}/shards/{id}` (raw BSON record data)
- Asset files: `thumb/{id}`, `display/{id}`, `asset/{id}`

The origin path is stored in `.db/config.json` (`origin` field). The `isPartial` flag lives in
the merkle tree's `databaseMetadata`.

Currently when the GUI requests any of these missing items, it gets empty data (shards silently
return no records because `serialization.load()` returns `undefined` on a missing file) or an
error (asset streams throw because `readStream()` rejects on a missing file).

This plan adds a `LazyOriginStorage` wrapper that transparently fetches missing files from the
origin database and caches them locally on first access.

---

## What Currently Works in Partial Mode

| Resource | Access path | Status |
|---|---|---|
| Sort index pages | `sortIndex().getPage()` → reads `tree.dat` (a `.dat` file, copied) | ✓ Works |
| Shard data | `serialization.load()` → `storage.read(shardFile)` | ✗ Returns empty |
| Thumb/display/asset files | `streamAsset()` → `storage.readStream(assetFile)` | ✗ Throws |

---

## Architecture

### `LazyOriginStorage` (new class)

A storage wrapper that implements `IStorage` by delegating to a `local` storage and an `origin`
storage. When a read returns nothing locally, it fetches from origin, caches to local, then
serves the result.

**Critical constraint**: `readStream()` must support files up to 7 GB (video files). It must
never buffer the full file in memory. Instead it uses a **tee stream** to simultaneously write
to the local cache and stream to the caller.

#### `read(path: string): Promise<Buffer | undefined>`
1. Call `local.read(path)`.
2. If result is defined, return it.
3. Call `origin.read(path)`.
4. If origin returns data, call `local.write(path, undefined, data)` to cache it.
5. Return the data (or `undefined` if origin also has nothing).

#### `readStream(path: string): Promise<Readable>`
1. If `await local.fileExists(path)`, return `local.readStream(path)`.
2. Otherwise: fetch from origin and tee the stream:
   - Get `originStream` via `origin.readStream(path)`.
   - Create two `PassThrough` streams: `cacheStream` and `callerStream`.
   - Forward data from `originStream` to both, with backpressure handling:
     - On `data`: write chunk to both PassThroughs; pause `originStream` if either returns
       `false` (backpressure).
     - On `drain` from either PassThrough: resume `originStream` only when neither is
       applying backpressure.
     - On `end`: end both PassThroughs.
     - On `error`: destroy both PassThroughs with the error.
   - Fire-and-forget: `local.writeStream(path, undefined, cacheStream).catch(() => {})`.
     Cache errors are non-fatal; the caller still receives the stream.
   - Return `callerStream`.

#### All other methods — delegate to `local` only:
- `write`, `writeStream`, `deleteFile`, `deleteDir`, `copyTo` → local (writes never go to origin)
- `fileExists`, `dirExists`, `isEmpty`, `info`, `listFiles`, `listDirs` → local (no eager fetch)
- `checkWriteLock`, `acquireWriteLock`, `releaseWriteLock`, `refreshWriteLock` → local

---

## Files to Create / Modify

### New: `packages/api/src/lib/lazy-origin-storage.ts`

Implements `LazyOriginStorage` as described above.

### Modify: `packages/api/src/lib/media-file-database.ts`

Add a new exported function:

```typescript
// Creates storage for the given database path, wrapping with LazyOriginStorage
// if the database is a partial replica with a known origin.
export async function createLazyDatabaseStorage(databasePath: string): Promise<IStorage>
```

Implementation:
1. `const { storage, rawStorage } = createStorage(databasePath, undefined, undefined);`
2. `const config = await loadDatabaseConfig(rawStorage);`
3. If `!config?.origin` → return `storage` unchanged.
4. `const merkleTree = await loadMerkleTree(storage);`
5. If `!merkleTree?.databaseMetadata?.isPartial` → return `storage` unchanged.
6. `const originStorage = createStorage(config.origin, undefined, undefined).storage;`
7. Return `new LazyOriginStorage(storage, originStorage)`.

Add required imports: `loadDatabaseConfig` from `./database-config`, `LazyOriginStorage`
from `./lazy-origin-storage`.

### Modify: `packages/rest-api/src/lib/asset-server.ts`

In `loadAssetStream()`, replace:
```typescript
const { storage: assetStorage } = createStorage(databasePath, undefined, undefined);
```
with:
```typescript
const assetStorage = await createLazyDatabaseStorage(databasePath);
```

Add import: `createLazyDatabaseStorage` from `api` (alongside existing `api` imports).
Remove the `createStorage` import if no longer used in this file.

### Modify: `packages/api/src/lib/apply-database-ops.ts`

In `applyDatabaseOps()`, replace:
```typescript
const { storage: assetStorage, rawStorage } = createStorage(databasePath, undefined, undefined);
```
with:
```typescript
const { rawStorage } = createStorage(databasePath, undefined, undefined);
const assetStorage = await createLazyDatabaseStorage(databasePath);
```

`rawStorage` stays unwrapped because write locks are always local operations.

Add import: `createLazyDatabaseStorage` from `./media-file-database`.

### Modify: `packages/api/src/lib/load-assets.worker.ts`

Replace:
```typescript
const { storage } = createStorage(data.databasePath, undefined, undefined);
```
with:
```typescript
const storage = await createLazyDatabaseStorage(data.databasePath);
```

Add import: `createLazyDatabaseStorage` from `./media-file-database`.
Remove `createStorage` import if no longer used.

---

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Large file handling in `readStream` | Tee stream (write-through) | 7 GB video files cannot be buffered in memory |
| Cache errors in `readStream` | Non-fatal (fire-and-forget) | Caller still receives the data even if caching fails |
| `read()` buffering | OK | Shard files and `.dat` files are typically < 1 MB |
| `fileExists` / `dirExists` | Local only, no fetch | Avoids eager fetching; sort index dirs exist because `.dat` files are present |
| Merkle tree update after caching | Not needed | `.db/files.dat` in partial mode already lists all files from origin |
| Concurrent fetches of same file | Allowed (race is idempotent) | Both writes produce identical data; acceptable for initial implementation |
| Write lock | Uses unwrapped `rawStorage` | Write locks are always local |
| Encrypted origins | Not supported | No decryption key available at read time |

---

## Tests

New file: `packages/api/src/test/lazy-origin-storage.test.ts`

- `read()` returns local data without calling origin when local has the file
- `read()` fetches from origin when local returns `undefined`, caches locally, returns data
- `read()` returns `undefined` when both local and origin have nothing
- `readStream()` returns local stream directly when file exists locally
- `readStream()` fetches from origin and tees when file is missing locally
- `readStream()` streams data correctly even if local cache write fails
- `write()` writes to local only and never touches origin
- `writeStream()` writes to local only and never touches origin

---

## Verification

1. `bun run compile` from repo root — TypeScript must compile clean.
2. `bun run test` from repo root — all tests must pass.
3. Manual test: create a partial replica with `--partial`, start the backend pointing to it,
   open the GUI — thumbnails, display images, and videos should load (pulled lazily from
   origin on first access, served from local cache on subsequent accesses).
4. Run `./apps/cli/smoke-tests.sh`.
