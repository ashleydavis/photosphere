# Plan: IPsi / Psi unified database wrapper

## Context

Database operations are currently split across multiple files:
- `packages/api/src/lib/media-file-database.ts` — free functions for assets, merkle tree, summary
- `apps/cli/src/lib/init-cmd.ts` — `loadDatabase()` / `createDatabase()` returning raw `IInitResult`
- `packages/api/src/lib/tree.ts` — load/save merkle tree helpers
- `packages/api/src/lib/write-lock.ts` — lock primitives

Every CLI command receives an `IInitResult` bag and then calls these free functions by passing individual fields (`assetStorage`, `bsonDatabase`, `metadataCollection`, etc.) around manually. A unified `IPsi` interface would make the call sites cleaner and provide a single object callers navigate to access subsystems.

User's intended API:
```ts
const psi: IPsi = ...
psi.database()       // → IBsonDatabase  (BSON DB + collections)
psi.files()          // → IMerkleRef<IDatabaseMetadata>  (lazy handle: .get() loads, .upsert()/.remove()/.commit() mutate)
psi.metadata()       // → IBsonCollection<IAsset>  (metadata collection)
```

Plus high-level convenience methods that currently live as free functions:
```ts
psi.summary()
psi.stream(assetId, assetType)
psi.write(...)
psi.writeStream(...)
psi.remove(assetId, recordDeleted)
```

---

## Implementation

### 1. New file: `packages/api/src/lib/photosphere.ts`

```ts
// Main interface
export interface IPsi {
    database(): IBsonDatabase;
    files(): IMerkleRef<IDatabaseMetadata>;
    metadata(): IBsonCollection<IAsset>;
    acquireWriteLock(): Promise<void>;
    refreshWriteLock(): Promise<void>;
    releaseWriteLock(): Promise<void>;
    commit(): Promise<void>;
    flush(): void;
    summary(): Promise<IDatabaseSummary>;
    stream(assetId: string, assetType: string): Promise<NodeJS.ReadableStream>;
    write(assetId: string, assetType: string, contentType: string | undefined, buffer: Buffer): Promise<void>;
    writeStream(assetId: string, assetType: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength: number | undefined): Promise<void>;
    remove(assetId: string, recordDeleted: boolean): Promise<void>;
}

// Implementation class
class Psi implements IPsi { ... }

// Factory
export function createPsi(
    assetStorage: IStorage,
    rawStorage: IStorage,
    sessionId: string,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider
): IPsi
```

The `Psi` class:
- Calls `createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider)` internally to obtain `bsonDatabase` and `metadataCollection`
- Holds `assetStorage`, `rawStorage`, `sessionId`, and the derived db/collection
- `database()` returns the internally-created `bsonDatabase`
- `files()` returns a `MerkleRef<IDatabaseMetadata>` constructed with `loadMerkleTree`/`saveMerkleTree` callbacks
- `metadata()` returns the internally-created `metadataCollection`
- `acquireWriteLock()` / `refreshWriteLock()` / `releaseWriteLock()` delegate to the lock primitives in `write-lock.ts`
- `commit()` delegates to `bsonDatabase.commit()`
- `flush()` delegates to `bsonDatabase.flush()`
- High-level methods (`write`, `writeStream`, `remove`) handle lock + commit + flush internally using the above

### 2. Update `packages/api/src/index.ts`

Add:
```ts
export * from "./lib/photosphere";
```

### 3. Update `apps/cli/src/lib/init-cmd.ts`

Both `loadDatabase()` and `createDatabase()` return `IInitResult`. Extend `IInitResult` to include a `psi` field:

```ts
export interface IInitResult {
    ...existing fields...
    psi: IPsi;
}
```

At the end of each function, replace the `createMediaFileDatabase` call + manual field spreading with:
```ts
const psi = createPsi(assetStorage, rawAssetStorage, sessionId, uuidGenerator, timestampProvider);
return { ..., psi };
```

`bsonDatabase` and `metadataCollection` in `IInitResult` can then be derived from `psi.database()` and `psi.metadata()` (or removed once callers migrate).

### 4. (Optional / follow-up) Migrate CLI commands

CLI commands that use `IInitResult` can progressively switch from calling free functions with spread args to using `result.psi.method(...)`. This is mechanical and can be done incrementally — the `IInitResult` fields remain available.

---

## Critical files

| File | Change |
|------|--------|
| `packages/bdb/src/lib/merkle-tree-ref.ts` | Make `IMerkleRef<T = undefined>` and `MerkleRef<T = undefined>` generic; `get()` returns `Promise<IMerkleTree<T> \| undefined>` |
| `packages/api/src/lib/photosphere.ts` | **Create** — `IPsi`, `Psi`, `createPsi` |
| `packages/api/src/index.ts` | Add `export * from "./lib/photosphere"` |
| `apps/cli/src/lib/init-cmd.ts` | Add `psi: IPsi` to `IInitResult`, populate in both factory functions |

## Reuse

- `MerkleRef<IDatabaseMetadata>` from `packages/bdb/src/lib/merkle-tree-ref.ts` — instantiated in `Psi` with `loadMerkleTree`/`saveMerkleTree` callbacks for `files()`
- `loadMerkleTree` / `saveMerkleTree` from `packages/api/src/lib/tree.ts` — used as callbacks in the `MerkleRef` constructor
- `acquireWriteLock`, `refreshWriteLock`, `releaseWriteLock` from `packages/api/src/lib/write-lock.ts` — delegated to from `Psi`
- `streamAsset`, `writeAsset`, `writeAssetStream`, `removeAsset`, `getDatabaseSummary` from `packages/api/src/lib/media-file-database.ts` — delegated to from `Psi`
- `createMediaFileDatabase` from `packages/api/src/lib/media-file-database.ts` — called inside `Psi` constructor to produce `bsonDatabase` and `metadataCollection`
- `IBsonDatabase`, `IBsonCollection` from `packages/bdb` — returned by `database()` / `metadata()`
- `IMerkleTree`, `IDatabaseMetadata` from `packages/merkle-tree` / `media-file-database.ts`

---

## Also: sort-index fix (pre-req or independent)

`packages/bdb/src/lib/sort-index.ts:112` — remove default type parameter from `ISortIndexResult`:
```ts
// Before
export interface ISortIndexResult<RecordT = ISortIndexRecord> {
// After
export interface ISortIndexResult<RecordT> {
```
No callers use the type without an explicit arg, so no other changes needed.

---

## Verification

1. `bun run compile` from root — no TypeScript errors
2. `bun run test` from root — all tests pass
3. Run `apps/cli/smoke-tests.sh` — all smoke tests pass
4. Spot-check a CLI command (e.g. `apps/cli/src/cmd/info.ts`) — confirm it can access `result.psi.metadata()` in lieu of `result.metadataCollection`
