# Zig port map

Every TypeScript source file the `psi` CLI bundles, the Zig file that ports it, and every TypeScript function with
the Zig function that ports it. Use it to read the two side by side: the Zig files have the same names and the same
function order as the TypeScript ones.

**Progress of the side by side comparison:** storage, bdb, api, lan-share-core, node-api, node-utils, utils,
encryption, vault, fuzzy-match, config, lan-share-network, serialization, merkle-tree and task-queue done. Still to
do: tools, apps/cli.

## Which files are listed

The list of files is what `bun build` bundles for `apps/cli/index.ts` and `apps/cli/worker.ts` (the TypeScript CLI's
two entry points), which is every file the CLI imports, directly or through a package's `index.ts`. A file whose code
is all types, or that only re-exports, is listed with a note saying so. A file that is bundled but that nothing the CLI
runs calls (a test helper or a desktop-only worker re-exported by a package's `index.ts`) is listed with the reason it
has no Zig counterpart.

## How to read the Zig side

- A TypeScript class is a Zig struct of the same name. Its constructor is `init`, and a class that implements an
  interface (for example `IStorage`) has a method returning the interface (`storage()`), which the TypeScript class
  does not need.
- Every function that allocates takes the caller's `allocator`, and every function that does I/O takes `io`. Neither
  is in the TypeScript signature.
- A thrown `Error` is `errors.throwError(...)`, which records the message and returns `error.Thrown`; a `WrappedError`
  is `errors.throwWrappedError(...)`. `undefined` is `null`.
- An arrow function passed to `retry` is a small struct with a `run` method and a `source` constant holding Bun's
  `toString()` of the arrow function (the retry timeout message quotes it).
- "Zig plumbing" marks Zig code with no TypeScript original that exists only because Zig has no garbage collector,
  interfaces, generators, closures or streams. "Replaces ..." marks Zig code that stands in for a node built-in, a
  runtime built-in or a third party npm package.

## storage

`packages/storage` to `packages-zig/storage-zig`. Zig only: `s3-client.zig` (the binding to the AWS SDK for C,
replacing `@aws-sdk/client-s3` and `@aws-sdk/lib-storage`) and `locale-compare.zig` (replaces the ICU collation behind
`localeCompare(other, undefined, { numeric: true })`).

<!-- tables: packages/storage storage.txt -->

#### `packages/storage/src/index.ts` to `packages-zig/storage-zig/src/index.zig`

Barrel file. `index.zig` re-exports the same modules; `tests/mock-storage` and `export * from "encryption"` are not re-exported (import encryption-zig directly).


#### `packages/storage/src/lib/cloud-storage.ts` to `packages-zig/storage-zig/src/lib/cloud-storage.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `CloudStorage` | `CloudStorage` |  |
| `CloudStorage.constructor` | `CloudStorage.init` |  |
| `CloudStorage.buildClient` | `CloudStorage.buildClient` | The client is the binding to the AWS SDK for C (`s3-client.zig`). `maxAttempts: 1` and `connectionTimeout` are set; aws-c-s3 has no whole request timeout, so `requestTimeout: 600000` has no counterpart. The `photosphereUnsignedPayload` middleware is the client signing every request with a body as UNSIGNED-PAYLOAD. |
| `CloudStorage.parsePath` | `CloudStorage.parsePath` |  |
| `CloudStorage.isEmpty` | `CloudStorage.isEmpty` |  |
| `CloudStorage.listFiles` | `CloudStorage.listFiles` |  |
| `CloudStorage.listDirs` | `CloudStorage.listDirs` |  |
| `CloudStorage.fileExists` | `CloudStorage.fileExists` |  |
| `CloudStorage.dirExists` | `CloudStorage.dirExists` |  |
| `CloudStorage.readableLength` | `CloudStorage.readableLength` |  |
| `CloudStorage.info` | `CloudStorage.info` |  |
| `CloudStorage.storedHash` | `CloudStorage.storedHash` |  |
| `CloudStorage.read` | `CloudStorage.read` |  |
| `CloudStorage.write` | `CloudStorage.write` |  |
| `CloudStorage.readStream` | `CloudStorage.readStream` |  |
| `CloudStorage.writeStream` | `CloudStorage.writeStream` |  |
| `CloudStorage.writeStreamHashed` | `CloudStorage.writeStreamHashed` |  |
| `CloudStorage.deleteFile` | `CloudStorage.deleteFile` |  |
| `CloudStorage.deleteDir` | `CloudStorage.deleteDir` |  |
| `CloudStorage.copyTo` | `CloudStorage.copyTo` |  |
| `CloudStorage.checkWriteLock` | `CloudStorage.checkWriteLock` |  |
| `CloudStorage.acquireWriteLock` | `CloudStorage.acquireWriteLock` |  |
| `CloudStorage.releaseWriteLock` | `CloudStorage.releaseWriteLock` |  |
| `CloudStorage.refreshWriteLock` | none | Not reached by the CLI (see `FileStorage.refreshWriteLock`). |
| none | `IS3Credentials` | The TypeScript interface of the same name, as a struct. |
| none | `IParsedPath` | The anonymous `{ bucket, key }` return type of `parsePath`. |
| none | `causeMessage` | The `err.message` of the error being wrapped, recorded so it can be the cause of the WrappedError. |
| none | `isNotFound` | `err.name === "NotFound" \|\| err.$metadata?.httpStatusCode === 404`. |
| none | `isNoSuchKey` | `err.name === "NoSuchKey"`. |
| none | `lastPathPart` | `item.Key!.split("/")` and taking the last part. |
| none | `bufferFromBase64` | Replaces `Buffer.from(text, "base64")`, lenient like the runtime's. |
| none | `CloudStorage.storage` | Zig plumbing: the IStorage view of the struct (a TypeScript class implements the interface directly). |

#### `packages/storage/src/lib/encrypted-storage.ts` to `packages-zig/storage-zig/src/lib/encrypted-storage.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `EncryptedStorage` | `EncryptedStorage` |  |
| `EncryptedStorage.constructor` | `EncryptedStorage.init` |  |
| `EncryptedStorage.isEmpty` | `EncryptedStorage.isEmpty` |  |
| `EncryptedStorage.listFiles` | `EncryptedStorage.listFiles` |  |
| `EncryptedStorage.listDirs` | `EncryptedStorage.listDirs` |  |
| `EncryptedStorage.fileExists` | `EncryptedStorage.fileExists` |  |
| `EncryptedStorage.dirExists` | `EncryptedStorage.dirExists` |  |
| `EncryptedStorage.readableLength` | `EncryptedStorage.readableLength` |  |
| `EncryptedStorage.writeStreamHashed` | `EncryptedStorage.writeStreamHashed` |  |
| `EncryptedStorage.storedHash` | `EncryptedStorage.storedHash` |  |
| `EncryptedStorage.info` | `EncryptedStorage.info` |  |
| `EncryptedStorage.read` | `EncryptedStorage.read` |  |
| `EncryptedStorage.write` | `EncryptedStorage.write` |  |
| `EncryptedStorage.readStream` | `EncryptedStorage.readStream` |  |
| `EncryptedStorage.writeStream` | `EncryptedStorage.writeStream` |  |
| `EncryptedStorage.deleteFile` | `EncryptedStorage.deleteFile` |  |
| `EncryptedStorage.deleteDir` | `EncryptedStorage.deleteDir` |  |
| `EncryptedStorage.copyTo` | `EncryptedStorage.copyTo` |  |
| `EncryptedStorage.checkWriteLock` | `EncryptedStorage.checkWriteLock` |  |
| `EncryptedStorage.acquireWriteLock` | `EncryptedStorage.acquireWriteLock` |  |
| `EncryptedStorage.releaseWriteLock` | `EncryptedStorage.releaseWriteLock` |  |
| `EncryptedStorage.refreshWriteLock` | none | Not reached by the CLI (see `FileStorage.refreshWriteLock`). |
| none | `EncryptedStorage.storage` | Zig plumbing: the IStorage view of the struct (a TypeScript class implements the interface directly). |
| none | `DecryptedReadStream` | Zig plumbing: `pipe(readStream, decryptionStream)`; holds both streams so `destroy` reaches the source. |
| none | `DecryptedReadStream.reader` | Zig plumbing: `pipe(readStream, decryptionStream)`; holds both streams so `destroy` reaches the source. |
| none | `DecryptedReadStream.destroy` | Zig plumbing: `pipe(readStream, decryptionStream)`; holds both streams so `destroy` reaches the source. |

#### `packages/storage/src/lib/file-storage.ts` to `packages-zig/storage-zig/src/lib/file-storage.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `temporaryWritePath` | `temporaryWritePath` |  |
| `FileStorage` | `FileStorage` |  |
| `FileStorage.constructor` | `FileStorage.init` |  |
| `FileStorage.isEmpty` | `FileStorage.isEmpty` |  |
| `FileStorage.listFiles` | `FileStorage.listFiles` |  |
| `FileStorage.listDirs` | `FileStorage.listDirs` |  |
| `FileStorage.fileExists` | `FileStorage.fileExists` |  |
| `FileStorage.dirExists` | `FileStorage.dirExists` |  |
| `FileStorage.readableLength` | `FileStorage.readableLength` |  |
| `FileStorage.writeStreamHashed` | `FileStorage.writeStreamHashed` |  |
| `FileStorage.storedHash` | `FileStorage.storedHash` |  |
| `FileStorage.info` | `FileStorage.info` |  |
| `FileStorage.read` | `FileStorage.read` |  |
| `FileStorage.write` | `FileStorage.write` |  |
| `FileStorage.readStream` | `FileStorage.readStream` |  |
| `FileStorage.writeStream` | `FileStorage.writeStream` | A `std.Io.Reader` carries no path, so the `IPathBearingStream` shortcut (`fs.copyFile` from the stream's source file) is not taken; the pipe writes the same bytes to the same temporary file. |
| `FileStorage.deleteFile` | `FileStorage.deleteFile` |  |
| `FileStorage.deleteDir` | `FileStorage.deleteDir` |  |
| `FileStorage.copyTo` | `FileStorage.copyTo` | Copies one file. TypeScript's fs-extra `copy` also copies a directory; nothing in the CLI calls `copyTo` (only `LazyOriginStorage.copyTo` forwards to it, and nothing calls that). |
| `FileStorage.checkWriteLock` | `FileStorage.checkWriteLock` |  |
| `FileStorage.acquireWriteLock` | `FileStorage.acquireWriteLock` | See "Divergences kept" for the empty lock file branch. |
| `FileStorage.releaseWriteLock` | `FileStorage.releaseWriteLock` |  |
| `FileStorage.refreshWriteLock` | none | Not reached by the CLI: only `writeAsset` and `writeAssetStream` in media-file-database.ts refresh the lock, and only the desktop asset server calls them. |
| none | `FileStorage.storage` | Zig plumbing: the IStorage view of the struct (a TypeScript class implements the interface directly). |
| none | `lockFileBeingWritten` | Zig only, kept on purpose: see "Divergences kept". An empty lock file younger than the timeout is being written by its owner and is refused rather than broken. |
| none | `logAcquireError` | The `catch` of the one try block around `acquireWriteLock`'s body: each fallible step passes its result through this to log ACQUIRE_FAILED_ERROR and rethrow. |
| none | `failAcquire` | Same `catch` block as `logAcquireError`, for an error already in hand. |
| none | `readDirNames` | Replaces `fs.readdir(path, { withFileTypes: true })` and the `isDirectory()` filter. |
| none | `dirname` | Replaces `path.dirname`. |
| none | `pipeline` | Replaces `pipeline(inputStream, createWriteStream(tmpPath))`. |
| none | `FileReadStream` | Replaces the node `fs.ReadStream` of `createReadStream` (closes the file at the end like `autoClose`). |
| none | `FileReadStream.reader` | Replaces the node `fs.ReadStream` of `createReadStream` (closes the file at the end like `autoClose`). |
| none | `FileReadStream.stream` | Replaces the node `fs.ReadStream` of `createReadStream` (closes the file at the end like `autoClose`). |
| none | `FileReadStream.close` | Replaces the node `fs.ReadStream` of `createReadStream` (closes the file at the end like `autoClose`). |
| none | `FileReadStream.destroy` | Replaces the node `fs.ReadStream` of `createReadStream` (closes the file at the end like `autoClose`). |
| none | `FileReadStream.readStream` | Replaces the node `fs.ReadStream` of `createReadStream` (closes the file at the end like `autoClose`). |
| none | `createReadStream` | Replaces node's `fs.createReadStream`; a missing file fails with node's ENOENT message. |

#### `packages/storage/src/lib/read-encryption-header.ts` to `packages-zig/storage-zig/src/lib/read-encryption-header.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `readFirstBytes` | `readFirstBytes` |  |
| `readEncryptionHeader` | `readEncryptionHeader` |  |
| none | `ReadFirstBytesOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ReadFirstBytesOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |

#### `packages/storage/src/lib/s3-path.ts` to `packages-zig/storage-zig/src/lib/s3-path.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `parseS3ListPath` | `parseS3ListPath` |  |
| none | `IS3PathParts` | The TypeScript interface of the same name, as a struct. |

#### `packages/storage/src/lib/s3-range-readable-stream.ts` to `packages-zig/storage-zig/src/lib/s3-range-readable-stream.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `S3RangeReadableStream` | `S3RangeReadableStream` |  |
| `S3RangeReadableStream.constructor` | `S3RangeReadableStream.init` |  |
| `S3RangeReadableStream._read` | `S3RangeReadableStream._read` |  |
| none | `S3RangeReadableStream.reader` | Zig plumbing: the `std.Io.Reader` side of a Node stream. |
| none | `S3RangeReadableStream.destroy` | Zig plumbing: the `std.Io.Reader` side of a Node stream. |
| none | `S3RangeReadableStream.readStream` | Zig plumbing: the `std.Io.Reader` side of a Node stream. |
| none | `S3RangeReadableStream.freeChunk` | Zig plumbing: frees the previous chunk (garbage collected in TypeScript). |
| none | `S3RangeReadableStream.streamFunction` | Zig plumbing: the `std.Io.Reader` side of a Node stream. |

#### `packages/storage/src/lib/storage-factory.ts` to `packages-zig/storage-zig/src/lib/storage-factory.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `pathJoin` | `pathJoin` |  |
| `createStorage` | `createStorage` |  |
| none | `ICreateStorageResult` | The TypeScript interface of the same name, as a struct. |
| none | `resolvePath` | Replaces `path.resolve(path)`. |

#### `packages/storage/src/lib/storage-prefix-wrapper.ts` to `packages-zig/storage-zig/src/lib/storage-prefix-wrapper.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `StoragePrefixWrapper` | `StoragePrefixWrapper` |  |
| `StoragePrefixWrapper.constructor` | `StoragePrefixWrapper.init` |  |
| `StoragePrefixWrapper.location` | `StoragePrefixWrapper.init` | The `location` getter: computed once in `init` into the `location` field, from the same `pathJoin`. |
| `StoragePrefixWrapper.makeFullPath` | `StoragePrefixWrapper.makeFullPath` |  |
| `StoragePrefixWrapper.isEmpty` | `StoragePrefixWrapper.isEmpty` |  |
| `StoragePrefixWrapper.listFiles` | `StoragePrefixWrapper.listFiles` |  |
| `StoragePrefixWrapper.listDirs` | `StoragePrefixWrapper.listDirs` |  |
| `StoragePrefixWrapper.fileExists` | `StoragePrefixWrapper.fileExists` |  |
| `StoragePrefixWrapper.dirExists` | `StoragePrefixWrapper.dirExists` |  |
| `StoragePrefixWrapper.readableLength` | `StoragePrefixWrapper.readableLength` |  |
| `StoragePrefixWrapper.writeStreamHashed` | `StoragePrefixWrapper.writeStreamHashed` |  |
| `StoragePrefixWrapper.storedHash` | `StoragePrefixWrapper.storedHash` |  |
| `StoragePrefixWrapper.info` | `StoragePrefixWrapper.info` |  |
| `StoragePrefixWrapper.read` | `StoragePrefixWrapper.read` |  |
| `StoragePrefixWrapper.write` | `StoragePrefixWrapper.write` |  |
| `StoragePrefixWrapper.readStream` | `StoragePrefixWrapper.readStream` |  |
| `StoragePrefixWrapper.writeStream` | `StoragePrefixWrapper.writeStream` |  |
| `StoragePrefixWrapper.deleteFile` | `StoragePrefixWrapper.deleteFile` |  |
| `StoragePrefixWrapper.deleteDir` | `StoragePrefixWrapper.deleteDir` |  |
| `StoragePrefixWrapper.copyTo` | `StoragePrefixWrapper.copyTo` |  |
| `StoragePrefixWrapper.checkWriteLock` | `StoragePrefixWrapper.checkWriteLock` |  |
| `StoragePrefixWrapper.acquireWriteLock` | `StoragePrefixWrapper.acquireWriteLock` |  |
| `StoragePrefixWrapper.releaseWriteLock` | `StoragePrefixWrapper.releaseWriteLock` |  |
| `StoragePrefixWrapper.refreshWriteLock` | none | Not reached by the CLI (see `FileStorage.refreshWriteLock`). |
| none | `StoragePrefixWrapper.storage` | Zig plumbing: the IStorage view of the struct (a TypeScript class implements the interface directly). |

#### `packages/storage/src/lib/storage.ts` to `packages-zig/storage-zig/src/lib/storage.zig`

Interfaces only in TypeScript. The Zig file holds the same interfaces plus the vtable plumbing a TypeScript interface gets for free, and the two helpers both storages use to read a lock file.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IListResult` | The TypeScript interface of the same name, as a struct. |
| none | `IFileInfo` | The TypeScript interface of the same name, as a struct. |
| none | `IWriteLockInfo` | The TypeScript interface of the same name, as a struct. |
| none | `LockFileContent` | The anonymous `{ owner, acquiredAt, timestamp }` object both storages write with `JSON.stringify` and read with `JSON.parse`, as a struct (same field order, so the same JSON). |
| none | `parseLockContent` | The `JSON.parse(lockContent.trim())` and `{ owner, acquiredAt: new Date(...), timestamp }` shared by `FileStorage.checkWriteLock` and `CloudStorage.checkWriteLock`. |
| none | `parseISOString` | Replaces the runtime's `new Date(isoString)` for the `toISOString` form the lock file holds. |
| none | `processId` | Replaces `process.pid`. |
| none | `IReadStream` | Zig plumbing: the `Readable` a `readStream` returns, as a `std.Io.Reader` plus `destroy`. |
| none | `IReadStream.reader` | Zig plumbing: the `std.Io.Reader` side of a Node stream. |
| none | `IReadStream.destroy` | Zig plumbing: the `std.Io.Reader` side of a Node stream. |
| none | `IStorage` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.isEmpty` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.listFiles` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.listDirs` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.fileExists` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.dirExists` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.readableLength` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.writeStreamHashed` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.storedHash` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.info` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.read` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.write` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.readStream` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.writeStream` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.deleteFile` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.deleteDir` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.copyTo` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.checkWriteLock` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.acquireWriteLock` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `IStorage.releaseWriteLock` | Zig plumbing: forwards the interface method to the implementation through the vtable. |
| none | `implement` | Zig plumbing: builds the IStorage vtable of a struct whose methods have the IStorage names. |
| none | `implementReadStream` | Zig plumbing: builds the IReadStream vtable of a stream struct. |

#### `packages/storage/src/lib/walk-directory.ts` to `packages-zig/storage-zig/src/lib/walk-directory.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `walkDirectory` | `walkDirectory` | Returns a `DirectoryWalker`; the two `do ... while (next)` loops and the recursion are `DirectoryWalker.next`. |
| none | `IOrderedFile` | The TypeScript interface of the same name, as a struct. |
| none | `matchesNodeModules` | The `/node_modules/` default ignore pattern (Zig has no RegExp; each pattern is a predicate). |
| none | `matchesGit` | The `/\.git/` default ignore pattern. |
| none | `matchesDsStore` | The `/\.DS_Store/` default ignore pattern. |
| none | `ListFilesOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ListFilesOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ListDirsOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ListDirsOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `WalkFrame` | Zig plumbing: one level of the recursive async generator (Zig has no generators). |
| none | `DirectoryWalker` | Zig plumbing: the async generator `walkDirectory` returns, as an explicit stack; `next` is one `yield`. |
| none | `DirectoryWalker.pushDirectory` | Zig plumbing: the async generator `walkDirectory` returns, as an explicit stack; `next` is one `yield`. |
| none | `DirectoryWalker.shouldIgnore` | Zig plumbing: the async generator `walkDirectory` returns, as an explicit stack; `next` is one `yield`. |
| none | `DirectoryWalker.next` | Zig plumbing: the async generator `walkDirectory` returns, as an explicit stack; `next` is one `yield`. |

#### `packages/storage/src/tests/mock-storage.ts` to no Zig file

Test helper, bundled only because `index.ts` re-exports it. Nothing the CLI runs calls it, so it is not ported (the Zig tests use `FileStorage` on a temporary directory and `src/test/recording-storage.zig`).

| TypeScript | Zig | Notes |
|---|---|---|
| `MockStorage` | none | Not reached by the CLI (test helper). |
| `MockStorage.constructor` | none | Not reached by the CLI (test helper). |
| `MockStorage.isEmpty` | none | Not reached by the CLI (test helper). |
| `MockStorage.read` | none | Not reached by the CLI (test helper). |
| `MockStorage.write` | none | Not reached by the CLI (test helper). |
| `MockStorage.deleteFile` | none | Not reached by the CLI (test helper). |
| `MockStorage.deleteDir` | none | Not reached by the CLI (test helper). |
| `MockStorage.fileExists` | none | Not reached by the CLI (test helper). |
| `MockStorage.dirExists` | none | Not reached by the CLI (test helper). |
| `MockStorage.listFiles` | none | Not reached by the CLI (test helper). |
| `MockStorage.listDirs` | none | Not reached by the CLI (test helper). |
| `MockStorage.info` | none | Not reached by the CLI (test helper). |
| `MockStorage.readableLength` | none | Not reached by the CLI (test helper). |
| `MockStorage.writeStreamHashed` | none | Not reached by the CLI (test helper). |
| `MockStorage.storedHash` | none | Not reached by the CLI (test helper). |
| `MockStorage.readStream` | none | Not reached by the CLI (test helper). |
| `MockStorage.writeStream` | none | Not reached by the CLI (test helper). |
| `MockStorage.copyTo` | none | Not reached by the CLI (test helper). |
| `MockStorage.checkWriteLock` | none | Not reached by the CLI (test helper). |
| `MockStorage.acquireWriteLock` | none | Not reached by the CLI (test helper). |
| `MockStorage.releaseWriteLock` | none | Not reached by the CLI (test helper). |
| `MockStorage.refreshWriteLock` | none | Not reached by the CLI (test helper). |

#### Zig files with no TypeScript file

| Zig file | What it is |
|---|---|
| `packages-zig/storage-zig/src/lib/locale-compare.zig` | Replaces ICU's `localeCompare(other, undefined, { numeric: true })` for FileStorage's listing order. ASCII is ordered as ICU orders it; see "JavaScript behaviour not emulated" for non-ASCII. |
| `packages-zig/storage-zig/src/lib/s3-client.zig` | Replaces the npm packages `@aws-sdk/client-s3` and `@aws-sdk/lib-storage` (the S3 client, its commands and `Upload`) with a binding to the AWS SDK for C (aws-c-s3), built from upstream sources. |

<!-- end tables -->

## bdb

`packages/bdb` to `packages-zig/bdb-zig`.

<!-- tables: packages/bdb bdb.txt -->

#### `packages/bdb/src/index.ts` to `packages-zig/bdb-zig/src/index.zig`

Barrel file. `index.zig` re-exports the same modules plus update-fields and update-metadata (for the tests) and the three Zig only files.


#### `packages/bdb/src/lib/collection.ts` to `packages-zig/bdb-zig/src/lib/collection.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `toInternal` | `toInternal` |  |
| `toExternal` | `toExternal` |  |
| `BsonCollection` | `BsonCollection` |  |
| `BsonCollection.constructor` | `BsonCollection.init` |  |
| `BsonCollection.dirty` | `BsonCollection.dirty` |  |
| `BsonCollection.markDirty` | `BsonCollection.markDirty` |  |
| `BsonCollection.clearDirty` | `BsonCollection.clearDirty` |  |
| `BsonCollection.sortIndex` | `BsonCollection.sortIndex` |  |
| `BsonCollection.addRecordToSortIndexes` | `BsonCollection.addRecordToSortIndexes` |  |
| `BsonCollection.updateRecordInSortIndexes` | `BsonCollection.updateRecordInSortIndexes` |  |
| `BsonCollection.deleteRecordFromSortIndexes` | `BsonCollection.deleteRecordFromSortIndexes` |  |
| `BsonCollection.merkleTree` | `BsonCollection.merkleTree` |  |
| `BsonCollection.shard` | `BsonCollection.shard` |  |
| `BsonCollection.evictShards` | `BsonCollection.evictShards` |  |
| `BsonCollection.getShardId` | `BsonCollection.getShardId` |  |
| `BsonCollection.insertOne` | `BsonCollection.insertOne` | The options object is the `timestamp` parameter (null for undefined). |
| `BsonCollection.getOne` | `BsonCollection.getOne` |  |
| `BsonCollection.iterateRecords` | `BsonCollection.iterateRecords` | Returns a `RecordIterator`; the async generator's loop is `RecordIterator.next`. |
| `BsonCollection.iterateShards` | `BsonCollection.iterateShards` | Returns a `ShardIterator`; the async generator's listing and loop are `ShardIterator.next`. |
| `BsonCollection.getAll` | `BsonCollection.getAll` | See "Divergences fixed": the continuation token is read with a port of `parseInt`. |
| `BsonCollection.updateOne` | `BsonCollection.updateOne` |  |
| `BsonCollection.replaceOne` | none | Not reached by the CLI: nothing in apps/cli, api or node-api calls replaceOne. |
| `BsonCollection.setInternalRecord` | `BsonCollection.setInternalRecord` |  |
| `BsonCollection.deleteOne` | `BsonCollection.deleteOne` |  |
| `BsonCollection.sortIndexes` | `BsonCollection.sortIndexes` |  |
| `BsonCollection.drop` | none | Not reached by the CLI: the CLI drops sort indexes (`SortIndex.drop`), never a whole collection. |
| `BsonCollection.commit` | `BsonCollection.commit` |  |
| `BsonCollection.flush` | `BsonCollection.flush` |  |
| none | `DirtyCallback` | Zig plumbing: the `() => void` onDirty and onDrop arrow functions, as a context and a function. |
| none | `IGetAllResult` | The TypeScript interface of the same name, as a struct. |
| none | `ISortIndexInfo` | The anonymous `{ fieldName, direction }` type of `sortIndexes`. |
| none | `IUpdateOptions` | The anonymous `{ upsert?, timestamp? }` options type of `updateOne`. |
| none | `RecordIterator` | Zig plumbing: the async generator `iterateRecords` returns. |
| none | `RecordIterator.next` | Zig plumbing: the async generator `iterateRecords` returns. |
| none | `ShardIterator` | Zig plumbing: the async generator `iterateShards` returns. |
| none | `ShardIterator.next` | Zig plumbing: the async generator `iterateShards` returns. |
| none | `ISortIndexDropContext` | Zig plumbing: what the `() => this.sortIndexCache.delete(cacheKey)` closure captures. |
| none | `BsonCollection.markDirtyCallback` | Zig plumbing: the `() => this.markDirty()` arrow function given to sort indexes. |
| none | `BsonCollection.evictSortIndexCallback` | Zig plumbing: the `() => this.sortIndexCache.delete(cacheKey)` arrow function. |
| none | `BsonCollection.merkleLoader` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonCollection.merkleSaver` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonCollection.merkleDeleter` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonCollection.merkleCreator` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonCollection.parseSortIndexDirectory` | `dir.match(/^(.+)_(asc\|desc)$/)`. |
| none | `jsNumberToString` | `String(shardId)` and the template string of the next token. |

#### `packages/bdb/src/lib/database.ts` to `packages-zig/bdb-zig/src/lib/database.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `BsonDatabase` | `BsonDatabase` |  |
| `BsonDatabase.constructor` | `BsonDatabase.init` |  |
| `BsonDatabase.markDirty` | `BsonDatabase.markDirty` |  |
| `BsonDatabase.clearDirty` | `BsonDatabase.clearDirty` |  |
| `BsonDatabase.collections` | `BsonDatabase.collections` |  |
| `BsonDatabase.collection` | `BsonDatabase.collection` |  |
| `BsonDatabase.commit` | `BsonDatabase.commit` |  |
| `BsonDatabase.flush` | `BsonDatabase.flush` |  |
| `BsonDatabase.merkleTree` | `BsonDatabase.merkleTree` |  |
| none | `BsonDatabase.markDirtyCallback` | Zig plumbing: the `() => this.markDirty()` arrow function given to collections. |
| none | `BsonDatabase.merkleLoader` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonDatabase.merkleSaver` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonDatabase.merkleDeleter` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonDatabase.merkleCreator` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |

#### `packages/bdb/src/lib/merge-records.ts` to `packages-zig/bdb-zig/src/lib/merge-records.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `isPrimitive` | `isPrimitive` |  |
| `mergeFields` | `mergeFields` |  |
| `mergeValues` | `mergeValues` |  |
| `cleanupMetadata` | `cleanupMetadata` |  |
| `mergeRecords` | `mergeRecords` |  |
| none | `MergeValueMetadata` | The inline type of `MergeValue.metadata`. |
| none | `MergeValue` | The TypeScript interface of the same name, as a struct. |
| none | `optionalNumber` | The operand of `??` for a metadata timestamp (null for missing, null or undefined). |
| none | `truthyNumber` | The operand of `\|\|` or `if` for a metadata timestamp (null for missing, zero or NaN). |
| none | `optionalMetadata` | The operand of `?.` for a metadata object. |
| none | `metadataToDocument` | Zig plumbing: a `MergeValue.metadata` as the BSON document it is stored as. |

#### `packages/bdb/src/lib/merkle-tree-ref.ts` to `packages-zig/bdb-zig/src/lib/merkle-tree-ref.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `MerkleRef` | `MerkleRef` |  |
| `MerkleRef.constructor` | `MerkleRef.init` |  |
| `MerkleRef.get` | `MerkleRef.get` |  |
| `MerkleRef.upsert` | `MerkleRef.upsert` |  |
| `MerkleRef.remove` | `MerkleRef.remove` |  |
| `MerkleRef.commit` | `MerkleRef.commit` |  |
| `MerkleRef.flush` | `MerkleRef.flush` |  |

#### `packages/bdb/src/lib/merkle-tree.ts` to `packages-zig/bdb-zig/src/lib/merkle-tree.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `hashRecord` | `hashRecord` |  |
| `buildShardMerkleTree` | `buildShardMerkleTree` |  |
| `saveShardMerkleTree` | `saveShardMerkleTree` |  |
| `deleteShardMerkleTree` | `deleteShardMerkleTree` |  |
| `loadShardMerkleTree` | `loadShardMerkleTree` |  |
| `listShards` | `listShards` |  |
| `buildCollectionMerkleTree` | `buildCollectionMerkleTree` |  |
| `saveCollectionMerkleTree` | `saveCollectionMerkleTree` |  |
| `loadCollectionMerkleTree` | `loadCollectionMerkleTree` |  |
| `deleteCollectionMerkleTree` | `deleteCollectionMerkleTree` |  |
| `listCollections` | `listCollections` |  |
| `buildDatabaseMerkleTree` | `buildDatabaseMerkleTree` |  |
| `saveDatabaseMerkleTree` | `saveDatabaseMerkleTree` |  |
| `loadDatabaseMerkleTree` | `loadDatabaseMerkleTree` |  |
| `deleteDatabaseMerkleTree` | `deleteDatabaseMerkleTree` |  |
| `databaseMerkleTreeExists` | none | Not reached by the CLI: nothing calls it. |
| `getDatabaseRootHash` | `getDatabaseRootHash` |  |
| none | `compareNamesLessThan` | The comparator of `shardIds.sort(compareNames)`. |
| none | `ignoreDirty` | The `() => {}` onDirty of the collection buildCollectionMerkleTree reads shards through. |

#### `packages/bdb/src/lib/shard.ts` to `packages-zig/bdb-zig/src/lib/shard.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `getRecordKey` | `getRecordKey` |  |
| `BsonShard` | `BsonShard` |  |
| `BsonShard.constructor` | `BsonShard.init` |  |
| `BsonShard.dirty` | `BsonShard.dirty` |  |
| `BsonShard.markDirty` | `BsonShard.markDirty` |  |
| `BsonShard.markClean` | `BsonShard.markClean` |  |
| `BsonShard.setRecord` | `BsonShard.setRecord` |  |
| `BsonShard.record` | `BsonShard.record` |  |
| `BsonShard.records` | `BsonShard.records` |  |
| `BsonShard.deleteRecord` | `BsonShard.deleteRecord` |  |
| `BsonShard.merkleTree` | `BsonShard.merkleTree` |  |
| `BsonShard.commit` | `BsonShard.commit` |  |
| `BsonShard.flush` | `BsonShard.flush` |  |
| `BsonShard.serializeRecord` | `BsonShard.serializeRecord` |  |
| `BsonShard.serializeShard` | `BsonShard.serializeShard` |  |
| `BsonShard.writeBsonFile` | `BsonShard.writeBsonFile` |  |
| `BsonShard.deserializeShardV1` | `BsonShard.deserializeShardV1` |  |
| `BsonShard.deserializeShardV2` | `BsonShard.deserializeShardV2` |  |
| `BsonShard.deserializeRecordV2` | `BsonShard.deserializeRecordV2` |  |
| `BsonShard.deserializeRecordV1` | `BsonShard.deserializeRecordV1` |  |
| `BsonShard.loadRecords` | `BsonShard.loadRecords` |  |
| `BsonShard.load` | `BsonShard.load` |  |
| none | `IInternalRecord` | The TypeScript interface of the same name, as a struct. |
| none | `recordIdToBuffer` | Replaces `Buffer.from(id.replace(/-/g, ''), 'hex')` (decodes up to the first pair that is not hex, like the runtime). |
| none | `BsonShard.merkleLoader` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonShard.merkleSaver` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonShard.merkleDeleter` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonShard.merkleCreator` | Zig plumbing: the four arrow functions `merkleTree()` hands to `new MerkleRef(...)`. |
| none | `BsonShard.recordLessThan` | The comparator `(recordA, recordB) => recordA._id.localeCompare(recordB._id)` of `serializeShard`. |

#### `packages/bdb/src/lib/sort-index.ts` to `packages-zig/bdb-zig/src/lib/sort-index.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `SortIndex` | `SortIndex` |  |
| `SortIndex.constructor` | `SortIndex.init` |  |
| `SortIndex.tryLoad` | `SortIndex.tryLoad` |  |
| `SortIndex.exists` | none | Not reached by the CLI: nothing calls it. |
| `SortIndex.ensure` | `SortIndex.ensure` | The progress callback is not ported (see `build`). |
| `SortIndex.markDirty` | `SortIndex.markDirty` |  |
| `SortIndex.deserializeTree` | `SortIndex.deserializeTree` |  |
| `SortIndex.load` | `SortIndex.load` |  |
| `SortIndex.reconstructParentChildRelationships` | `SortIndex.reconstructParentChildRelationships` |  |
| `SortIndex.serializeNode` | `SortIndex.serializeNode` |  |
| `SortIndex.deserializeNode` | `SortIndex.deserializeNode` |  |
| `SortIndex.serializeTree` | `SortIndex.serializeTree` |  |
| `SortIndex.saveCheckpoint` | `SortIndex.saveCheckpoint` |  |
| `SortIndex.loadCheckpoint` | `SortIndex.loadCheckpoint` |  |
| `SortIndex.deleteCheckpoint` | `SortIndex.deleteCheckpoint` |  |
| `SortIndex.build` | `SortIndex.build` | The progress callback and its timing report are not ported: no caller in the CLI passes one. |
| `SortIndex.findLeftmostLeaf` | `SortIndex.findLeftmostLeaf` |  |
| `SortIndex.compareValues` | `SortIndex.compareValues` |  |
| `SortIndex.serializeLeafRecords` | `SortIndex.serializeLeafRecords` |  |
| `SortIndex.updateLeaf` | `SortIndex.updateLeaf` |  |
| `SortIndex.deserializeLeafRecords` | `SortIndex.deserializeLeafRecords` |  |
| `SortIndex.loadLeafRecords` | `SortIndex.loadLeafRecords` |  |
| `SortIndex.markLeafForDelete` | `SortIndex.markLeafForDelete` |  |
| `SortIndex.dirty` | `SortIndex.dirty` |  |
| `SortIndex.commit` | `SortIndex.commit` |  |
| `SortIndex.flush` | `SortIndex.flush` |  |
| `SortIndex.getNode` | `SortIndex.getNode` |  |
| `SortIndex.getPage` | `SortIndex.getPage` |  |
| `SortIndex.drop` | `SortIndex.drop` |  |
| `SortIndex.updateRecord` | `SortIndex.updateRecord` |  |
| `SortIndex.deleteRecord` | `SortIndex.deleteRecord` |  |
| `SortIndex.findLeafForValue` | `SortIndex.findLeafForValue` |  |
| `SortIndex.updateKeyInParents` | `SortIndex.updateKeyInParents` |  |
| `SortIndex.addRecord` | `SortIndex.addRecord` |  |
| `SortIndex.splitLeafNodeInternal` | `SortIndex.splitLeafNodeInternal` |  |
| `SortIndex.splitLeafNode` | `SortIndex.splitLeafNode` |  |
| `SortIndex.findByValue` | `SortIndex.findByValue` |  |
| `SortIndex.findByRange` | none | Not reached by the CLI: nothing calls it. |
| `SortIndex.splitInternalNode` | `SortIndex.splitInternalNode` |  |
| `SortIndex.formatValueForDisplay` | none | Not reached by the CLI: only visualizeTree calls it. |
| `SortIndex.visualizeTree` | none | Not reached by the CLI: `psi debug merkle-tree` visualizes merkle trees with merkle-tree's `visualizeTree`, not sort indexes. |
| `SortIndex.analyzeTreeStructure` | none | Not reached by the CLI: nothing calls it. |
| none | `SortDirection` | The `'asc' \| 'desc'` type, as an enum. |
| none | `SortDataType` | The `'date' \| 'string' \| 'number'` type, as an enum. |
| none | `ITreeData` | The TypeScript interface of the same name, as a struct. |
| none | `ISortedIndexEntry` | The TypeScript interface of the same name, as a struct. |
| none | `IFieldValue` | The TypeScript interface of the same name, as a struct. |
| none | `getFieldValue` | `record.fields[this.fieldName]`, with the field's address standing in for its JavaScript object identity. |
| none | `strictEqualsValue` | `entry.value === value`, objects compared by the identity getFieldValue records. |
| none | `ISortIndexResult` | The TypeScript interface of the same name, as a struct. |
| none | `ILeafCacheEntry` | The TypeScript interface of the same name, as a struct. |
| none | `IBTreeNode` | The TypeScript interface of the same name, as a struct. |
| none | `IBuildCheckpoint` | The TypeScript interface of the same name, as a struct. |
| none | `isSet` | A page id's truthiness (`if (pageId)`). |
| none | `samePageId` | `===` on two `string \| undefined` page ids. |
| none | `indexOfChild` | `children.indexOf(id)`. |
| none | `findEntryIndex` | `leafRecords.findIndex(entry => entry._id === recordId)`. |
| none | `SortIndex.setParentsForChildren` | The `setParentsForChildren` arrow function inside `reconstructParentChildRelationships`. |
| none | `SortIndex.pageIdLessThan` | The comparator `([a], [b]) => a.localeCompare(b)` of `serializeTree`. |
| none | `SortIndex.flushDirtyNodes` | The `flushDirtyNodes` arrow function inside `build`. |
| none | `SortIndex.addRecordBatched` | The `addRecordBatched` arrow function inside `build`. |
| none | `SortIndex.isShardCompleted` | `checkpoint.completedShards.includes(shardIndex)`. |
| none | `SortIndex.sortEntries` | `records.sort((a, b) => this.compareValues(a.value, b.value))`: a stable sort, like Array.prototype.sort, that can throw from the comparator. |
| none | `SortIndex.toSortIndexRecord` | `({ _id: entry._id, ...entry.fields })`. |
| none | `SortIndex.appendMatches` | `leafRecords.filter(entry => entry.value === value)` pushed onto the matches. |

#### `packages/bdb/src/lib/update-fields.ts` to `packages-zig/bdb-zig/src/lib/update-fields.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `updateFields` | `updateFields` |  |

#### `packages/bdb/src/lib/update-metadata.ts` to `packages-zig/bdb-zig/src/lib/update-metadata.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `updateMetadata` | `updateMetadata` |  |
| none | `metadataTimestamp` | `metadata.timestamp ?? 0`. |
| none | `metadataObject` | `value \|\| {}` for a metadata object. |
| none | `timestampMetadata` | The object literal `{ timestamp: writeTimestamp }`. |

#### `packages/bdb/src/tests/mock-collection.ts` to no Zig file

Test helpers, bundled only because `index.ts` re-exports them. Nothing the CLI runs uses them, so they are not ported (the Zig tests use `src/test/memory-storage.zig`, a port of MockStorage).

| TypeScript | Zig | Notes |
|---|---|---|
| `NoopMerkleRef` | none | Not reached by the CLI (test helper). |
| `NoopMerkleRef.get` | none | Not reached by the CLI (test helper). |
| `NoopMerkleRef.upsert` | none | Not reached by the CLI (test helper). |
| `NoopMerkleRef.remove` | none | Not reached by the CLI (test helper). |
| `NoopMerkleRef.commit` | none | Not reached by the CLI (test helper). |
| `NoopMerkleRef.flush` | none | Not reached by the CLI (test helper). |
| `MockCollection` | none | Not reached by the CLI (test helper). |
| `MockCollection.constructor` | none | Not reached by the CLI (test helper). |
| `MockCollection.insertOne` | none | Not reached by the CLI (test helper). |
| `MockCollection.getOne` | none | Not reached by the CLI (test helper). |
| `MockCollection.iterateRecords` | none | Not reached by the CLI (test helper). |
| `MockCollection.iterateShards` | none | Not reached by the CLI (test helper). |
| `MockCollection.getAll` | none | Not reached by the CLI (test helper). |
| `MockCollection.sortIndexes` | none | Not reached by the CLI (test helper). |
| `MockCollection.sortIndex` | none | Not reached by the CLI (test helper). |
| `MockCollection.updateOne` | none | Not reached by the CLI (test helper). |
| `MockCollection.replaceOne` | none | Not reached by the CLI (test helper). |
| `MockCollection.setInternalRecord` | none | Not reached by the CLI (test helper). |
| `MockCollection.deleteOne` | none | Not reached by the CLI (test helper). |
| `MockCollection.ensureIndex` | none | Not reached by the CLI (test helper). |
| `MockCollection.shutdown` | none | Not reached by the CLI (test helper). |
| `MockCollection.drop` | none | Not reached by the CLI (test helper). |
| `MockCollection.shard` | none | Not reached by the CLI (test helper). |
| `MockCollection.getShardId` | none | Not reached by the CLI (test helper). |
| `MockCollection.dirty` | none | Not reached by the CLI (test helper). |
| `MockCollection.commit` | none | Not reached by the CLI (test helper). |
| `MockCollection.flush` | none | Not reached by the CLI (test helper). |
| `MockCollection.merkleTree` | none | Not reached by the CLI (test helper). |

#### `packages/bdb/src/tests/mock-database.ts` to no Zig file

Test helper, not reached by the CLI (see mock-collection.ts).

| TypeScript | Zig | Notes |
|---|---|---|
| `MockDatabase` | none | Not reached by the CLI (test helper). |
| `MockDatabase.collection` | none | Not reached by the CLI (test helper). |
| `MockDatabase.collections` | none | Not reached by the CLI (test helper). |
| `MockDatabase.commit` | none | Not reached by the CLI (test helper). |
| `MockDatabase.flush` | none | Not reached by the CLI (test helper). |
| `MockDatabase.merkleTree` | none | Not reached by the CLI (test helper). |
| `MockDatabase.getMockCollection` | none | Not reached by the CLI (test helper). |

#### Zig files with no TypeScript file

| Zig file | What it is |
|---|---|
| `packages-zig/bdb-zig/src/lib/js-value.zig` | Replaces the JavaScript language semantics the bdb code relies on implicitly (`String(x)`, `Number(x)`, `<`, `===`, `typeof`, `JSON.stringify(x, null, 2)`, `toJSON`) for the values npm bson deserializes. |
| `packages-zig/bdb-zig/src/lib/json-stable-stringify.zig` | Replaces the npm package `json-stable-stringify` 1.3.0 (`stringify(obj)` with no options), which `hashRecord` calls. |
| `packages-zig/bdb-zig/src/lib/locale-compare.zig` | Replaces ICU's `localeCompare(other)` (no options), which orders shard records, tree pages and string sort values. See "JavaScript behaviour not emulated" for non-ASCII. |

<!-- end tables -->

## api

`packages/api` to `packages-zig/api-zig`. The `lan-share` directory of the TypeScript package is `src/lib/lan-share` in
Zig.

<!-- tables: packages/api api.txt -->

#### `packages/api/src/index.ts` to `packages-zig/api-zig/src/index.zig`

Barrel file. `index.zig` exports the ported modules; the files not ported are listed below with the reason.


#### `packages/api/src/lan-share/index.ts` to `packages-zig/api-zig/src/lib/lan-share/index.zig`

Types only. The Zig file (under lib/) re-exports the lan-share-core payload types and holds IShareDatabaseConfig; the task data and result types of the desktop's LAN share tasks are not ported (the CLI shares directly, not through tasks).

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IShareDatabaseConfig` | The TypeScript interface of the same name, as a struct. |

#### `packages/api/src/lan-share/lan-share-receive.ts` to `packages-zig/api-zig/src/lib/lan-share/lan-share-receive.zig`

The Zig file is under lib/.

| TypeScript | Zig | Notes |
|---|---|---|
| `vaultSecretStore` | `vaultSecretStore` |  |
| `importDatabasePayload` | `importDatabasePayload` |  |
| `importSecretPayload` | `importSecretPayload` |  |
| none | `IVaultSecretStoreContext` | Zig plumbing: what the object literal `vaultSecretStore` returns closes over. |
| none | `vaultHas` | The `has` arrow function of `vaultSecretStore`. |
| none | `vaultWrite` | The `write` arrow function of `vaultSecretStore`. |

#### `packages/api/src/lan-share/lan-share-resolve.ts` to `packages-zig/api-zig/src/lib/lan-share/lan-share-resolve.zig`

The Zig file is under lib/. See "Divergences fixed" for credentials without a region.

| TypeScript | Zig | Notes |
|---|---|---|
| `resolveDatabaseSharePayload` | `resolveDatabaseSharePayload` |  |
| `resolveSecretSharePayload` | `resolveSecretSharePayload` |  |
| none | `s3CredentialField` | `parsed.region` (and the other fields) of the parsed S3 credentials. |

#### `packages/api/src/lib/asset-query.ts` to `packages-zig/api-zig/src/lib/asset-query.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `listAssetPage` | `listAssetPage` |  |
| `searchAssets` | `searchAssets` | `toLowerCase` is ASCII only in Zig; see "JavaScript behaviour not emulated". |
| `matchesAsset` | `matchesAsset` |  |
| `getAsset` | `getAsset` |  |
| `streamAssetToFile` | `streamAssetToFile` | See "Divergences fixed": the output file is made before the read stream is opened. |
| `mapAssetTypeToStorageKey` | `mapAssetTypeToStorageKey` |  |
| none | `IListAssetsResult` | The TypeScript interface of the same name, as a struct. |
| none | `AssetExportType` | The string union type, as an enum. |
| none | `isTruthy` | The truthiness tests of optional strings. |
| none | `stringField` | `asset.field \|\| ""`. |
| none | `photoDateMs` | `!asset.photoDate` and `Date.parse(asset.photoDate)`. |

#### `packages/api/src/lib/asset.ts` to no Zig file

Types only (IAsset). Zig records are the BSON documents they are stored as.


#### `packages/api/src/lib/auto-import-mobile.ts` to no Zig file

Not reached by the CLI: only the mobile app and the desktop's config and default database workers use it.

| TypeScript | Zig | Notes |
|---|---|---|
| `resolveAutoImportPauseMs` | none | Not reached by the CLI (mobile only). |
| `planMobileAutoImport` | none | Not reached by the CLI (mobile only). |

#### `packages/api/src/lib/auto-import-queue.ts` to `packages-zig/api-zig/src/lib/auto-import-queue.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `AutoImportQueue` | `AutoImportQueue` |  |
| `AutoImportQueue.addItems` | `AutoImportQueue.addItems` |  |
| `AutoImportQueue.nextItem` | `AutoImportQueue.nextItem` |  |
| `AutoImportQueue.hasPending` | `AutoImportQueue.hasPending` |  |
| `AutoImportQueue.pendingCount` | `AutoImportQueue.pendingCount` |  |
| none | `AutoImportQueue.init` | Zig plumbing: the class's field initializers. |

#### `packages/api/src/lib/auto-import-settings.ts` to `packages-zig/api-zig/src/lib/auto-import-settings.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `isBoolean` | `isBoolean` |  |
| `isNonEmptyString` | `isNonEmptyString` |  |
| `normaliseAutoImportSource` | `normaliseAutoImportSource` |  |
| `normaliseAutoImportSettings` | `normaliseAutoImportSettings` |  |
| none | `IFolderAutoImportSource` | The TypeScript interface of the same name, as a struct. |
| none | `IDeviceAlbumAutoImportSource` | The TypeScript interface of the same name, as a struct. |
| none | `IAutoImportSource` | The TypeScript interface of the same name, as a struct. |
| none | `IAutoImportSource.sourceType` | The `type` discriminator of the union. |
| none | `IAutoImportSettings` | The TypeScript interface of the same name, as a struct. |
| none | `autoImportSourceToJson` | Zig plumbing: the source as the plain object TypeScript stores and queues. |
| none | `autoImportSourcesToJson` | Zig plumbing: the sources as the plain array TypeScript stores and queues. |
| none | `autoImportSettingsToJson` | Zig plumbing: the settings as the plain object TypeScript stores and queues. |

#### `packages/api/src/lib/constants.ts` to `packages-zig/api-zig/src/lib/constants.zig`


#### `packages/api/src/lib/database-config.ts` to `packages-zig/api-zig/src/lib/database-config.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `loadDatabaseConfig` | `loadDatabaseConfig` |  |
| `saveDatabaseConfig` | `saveDatabaseConfig` |  |
| `updateDatabaseConfig` | `updateDatabaseConfig` |  |
| none | `IDatabaseConfig` | The TypeScript interface of the same name, as a struct. |
| none | `ReadConfigOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ReadConfigOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `WriteConfigOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `WriteConfigOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |

#### `packages/api/src/lib/database-descriptor.ts` to `packages-zig/api-zig/src/lib/database-descriptor.zig`

Types only.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IDatabaseDescriptor` | The TypeScript interface of the same name, as a struct. |

#### `packages/api/src/lib/database-op-record.ts` to no Zig file

Types only; not reached by the CLI.


#### `packages/api/src/lib/database-op.ts` to no Zig file

Types only; the database operations are not reached by the CLI.


#### `packages/api/src/lib/database-state.ts` to `packages-zig/api-zig/src/lib/database-state.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `serializeDatabaseState` | `serializeDatabaseState` |  |
| `deserializeCommonDatabaseState` | `deserializeCommonDatabaseState` |  |
| `deserializeAnyDatabaseState` | `deserializeAnyDatabaseState` |  |
| `loadDatabaseState` | `loadDatabaseState` |  |
| `saveDatabaseState` | `saveDatabaseState` |  |
| `mergeDatabaseState` | `mergeDatabaseState` |  |
| `updateDatabaseStateLocked` | `updateDatabaseStateLocked` |  |
| none | `IDatabaseState` | The TypeScript interface of the same name, as a struct. |

#### `packages/api/src/lib/database-update.ts` to no Zig file

Types only; not reached by the CLI.


#### `packages/api/src/lib/import-assets.types.ts` to `packages-zig/api-zig/src/lib/import-assets.types.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IFileCacheIdentity` | The TypeScript interface of the same name, as a struct. |
| none | `IImportedAsset` | The TypeScript interface of the same name, as a struct. |
| none | `ISkippedImport` | The TypeScript interface of the same name, as a struct. |
| none | `IImportAssetsResult` | The TypeScript interface of the same name, as a struct. |

#### `packages/api/src/lib/import-record.ts` to `packages-zig/api-zig/src/lib/import-record.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `createImportRecord` | `createImportRecord` |  |
| `addImportEntries` | `addImportEntries` |  |
| `parseImportRecord` | `parseImportRecord` |  |
| `serializeImportRecord` | `serializeImportRecord` |  |
| none | `ImportSource` | The string union type, as an enum. |
| none | `ImportOutcome` | The string union type, as an enum. |
| none | `IImportRecordEntry` | The TypeScript interface of the same name, as a struct. |
| none | `IImportRecord` | The TypeScript interface of the same name, as a struct. |
| none | `stringProperty` | `typeof candidate.x === "string" ? candidate.x : ...`. |

#### `packages/api/src/lib/load-assets.ts` to no Zig file

Not reached by the CLI: only the load-assets worker of the apps uses it.

| TypeScript | Zig | Notes |
|---|---|---|
| `loadAssets` | none | Not reached by the CLI (see the file). |

#### `packages/api/src/lib/load-assets.types.ts` to no Zig file

Types only; not reached by the CLI.


#### `packages/api/src/lib/media-source.ts` to `packages-zig/api-zig/src/lib/media-source.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `MediaSourceDeleteError` | `MediaSourceDeleteError` |  |
| `MediaSourceDeleteError.constructor` | `MediaSourceDeleteError.throw` | `throw new MediaSourceDeleteError(message, sourceIds)`. |
| none | `IMediaItem` | The TypeScript interface of the same name, as a struct. |
| none | `IMediaSourceListPage` | The TypeScript interface of the same name, as a struct. |
| none | `IMediaSource` | The TypeScript interface of the same name, as a struct. |
| none | `IMediaSource.listPage` | Zig plumbing: forwards the interface method through the vtable. |
| none | `IMediaSource.openItem` | Zig plumbing: forwards the interface method through the vtable. |
| none | `IMediaSource.closeItem` | Zig plumbing: forwards the interface method through the vtable. |
| none | `IMediaSource.deleteItems` | Zig plumbing: forwards the interface method through the vtable. |
| none | `MediaSourceDeleteError.isInstance` | `error instanceof MediaSourceDeleteError`. |
| none | `MediaSourceDeleteError.sourceIds` | `error.sourceIds` (a Zig error carries no data, so the ids are kept beside it). |

#### `packages/api/src/lib/op.ts` to no Zig file

Types only; not reached by the CLI.


#### `packages/api/src/lib/replicate-database.types.ts` to `packages-zig/api-zig/src/lib/replicate-database.types.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IReplicateDatabaseData` | The TypeScript interface of the same name, as a struct. |
| none | `IReplicateProgressMessage` | The TypeScript interface of the same name, as a struct. |

#### `packages/api/src/lib/retention-policy.ts` to no Zig file

Not reached by the CLI: only the evict-originals worker uses it, which the CLI never queues.

| TypeScript | Zig | Notes |
|---|---|---|
| `evictableOldestFirst` | none | Not reached by the CLI (see the file). |
| `SizeBudgetRetentionPolicy` | none | Not reached by the CLI (see the file). |
| `SizeBudgetRetentionPolicy.constructor` | none | Not reached by the CLI (see the file). |
| `SizeBudgetRetentionPolicy.selectForEviction` | none | Not reached by the CLI (see the file). |
| `RecentDaysRetentionPolicy` | none | Not reached by the CLI (see the file). |
| `RecentDaysRetentionPolicy.constructor` | none | Not reached by the CLI (see the file). |
| `RecentDaysRetentionPolicy.selectForEviction` | none | Not reached by the CLI (see the file). |
| `FreeSpaceRetentionPolicy` | none | Not reached by the CLI (see the file). |
| `FreeSpaceRetentionPolicy.constructor` | none | Not reached by the CLI (see the file). |
| `FreeSpaceRetentionPolicy.selectForEviction` | none | Not reached by the CLI (see the file). |
| `DropWhenConfirmedRetentionPolicy` | none | Not reached by the CLI (see the file). |
| `DropWhenConfirmedRetentionPolicy.selectForEviction` | none | Not reached by the CLI (see the file). |

#### `packages/api/src/lib/save-assets.types.ts` to no Zig file

Types only; not reached by the CLI.


#### `packages/api/src/lib/source-cleanup.ts` to `packages-zig/api-zig/src/lib/source-cleanup.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `selectConfirmedForCleanup` | none | Not reached by the CLI: nothing calls it outside its tests. |
| `runSourceCleanup` | `runSourceCleanup` |  |
| none | `ISourceCleanupResult` | The TypeScript interface of the same name, as a struct. |
| none | `containsString` | `new Set(error.sourceIds).has(sourceId)`. |

#### `packages/api/src/lib/sync-database.types.ts` to `packages-zig/api-zig/src/lib/sync-database.types.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `SyncChangeType` | The string union type of a sync change, as an enum. |
| none | `ISyncChange` | The TypeScript interface of the same name, as a struct. |

#### `packages/api/src/lib/sync-gate.ts` to no Zig file

Not reached by the CLI: the apps' automatic sync decides with it.

| TypeScript | Zig | Notes |
|---|---|---|
| `computeSyncAllowed` | none | Not reached by the CLI (see the file). |

#### `packages/api/src/lib/sync-settings.ts` to no Zig file

Not reached by the CLI: the apps' sync settings and the desktop's config worker use it.

| TypeScript | Zig | Notes |
|---|---|---|
| `normaliseSyncSettings` | none | Not reached by the CLI (see the file). |
| `resolveSyncPauseMs` | none | Not reached by the CLI (see the file). |

#### `packages/api/src/lib/write-lock.ts` to `packages-zig/api-zig/src/lib/write-lock.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `acquireWriteLock` | `acquireWriteLock` |  |
| `refreshWriteLock` | none | Not reached by the CLI (see storage `FileStorage.refreshWriteLock`). |
| `releaseWriteLock` | `releaseWriteLock` |  |
| none | `mathRound` | Replaces `Math.round`. |
| none | `ReleaseWriteLockOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ReleaseWriteLockOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |

<!-- end tables -->

## lan-share-core

`packages/lan-share-core` to `packages-zig/lan-share-core-zig`.

<!-- tables: packages/lan-share-core lan-share-core.txt -->

#### `packages/lan-share-core/src/index.ts` to `packages-zig/lan-share-core-zig/src/index.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `resolveConflict` | `resolveConflict` |  |
| `importShareSecrets` | `importShareSecrets` |  |
| none | `ISecretSharePayload` | The TypeScript interface of the same name, as a struct. |
| none | `IShareS3Credentials` | The region and the two keys are optional in Zig: see "Divergences fixed". |
| none | `IShareEncryptionKey` | The TypeScript interface of the same name, as a struct. |
| none | `IShareGeocodingKey` | The TypeScript interface of the same name, as a struct. |
| none | `IDatabaseSharePayload` | The TypeScript interface of the same name, as a struct. |
| none | `ConflictAction` | The `"replace" \| "reuse" \| "rename"` union of IConflictResolution.action, as an enum. |
| none | `IConflictResolution` | The TypeScript interface of the same name, as a struct. |
| none | `ConflictResolver` | The ConflictResolver function type, as a context and a function. |
| none | `IShareSecretStore` | The TypeScript interface of the same name, as a struct. |
| none | `IShareResolvedKeys` | The TypeScript interface of the same name, as a struct. |
| none | `IResolvedSecret` | The TypeScript interface of the same name, as a struct. |
| none | `IStoredS3Credentials` | The object literal `importShareSecrets` stores with JSON.stringify (same key order; undefined keys left out). |

<!-- end tables -->

## node-api

`packages/node-api` to `packages-zig/node-api-zig`. Zig only: `fetch.zig` (replaces the global `fetch`),
`retry-operations.zig` (the arrow functions node-api passes to `retry`), and under `third-party` the ports of the
`exif-parser`, `jszip`, `lodash/throttle` and `mime` npm packages. The worker tasks the desktop and mobile apps queue
and the CLI never does are listed with no Zig file.

<!-- tables: packages/node-api node-api.txt -->

#### `packages/node-api/src/index.ts` to `packages-zig/node-api-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/node-api/src/lib/app-config-format.ts` to no Zig file

Not reached by the CLI: the desktop and mobile apps' settings and remembered interface state (config.yaml and the app state). The CLI keeps its settings in databases.toml and state.yaml.

| TypeScript | Zig | Notes |
|---|---|---|
| `getAppConfigValue` | none | Not reached by the CLI (see the file note). |
| `setAppConfigValue` | none | Not reached by the CLI (see the file note). |
| `appConfigSettings` | none | Not reached by the CLI (see the file note). |
| `isSection` | none | Not reached by the CLI (see the file note). |
| `documentSources` | none | Not reached by the CLI (see the file note). |
| `yamlToAppConfig` | none | Not reached by the CLI (see the file note). |
| `sourceToYaml` | none | Not reached by the CLI (see the file note). |
| `writeField` | none | Not reached by the CLI (see the file note). |
| `writeSection` | none | Not reached by the CLI (see the file note). |
| `appConfigToYaml` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/app-config.ts` to no Zig file

Not reached by the CLI: the desktop and mobile apps' settings and remembered interface state (config.yaml and the app state). The CLI keeps its settings in databases.toml and state.yaml.

| TypeScript | Zig | Notes |
|---|---|---|
| `loadAppConfig` | none | Not reached by the CLI (see the file note). |
| `updateAppConfig` | none | Not reached by the CLI (see the file note). |
| `getTheme` | none | Not reached by the CLI (see the file note). |
| `setTheme` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/app-state-format.ts` to no Zig file

Not reached by the CLI: the desktop and mobile apps' settings and remembered interface state (config.yaml and the app state). The CLI keeps its settings in databases.toml and state.yaml.

| TypeScript | Zig | Notes |
|---|---|---|
| `getAppStateValue` | none | Not reached by the CLI (see the file note). |
| `setAppStateValue` | none | Not reached by the CLI (see the file note). |
| `appStateSettings` | none | Not reached by the CLI (see the file note). |
| `isSection` | none | Not reached by the CLI (see the file note). |
| `yamlToAppState` | none | Not reached by the CLI (see the file note). |
| `writeField` | none | Not reached by the CLI (see the file note). |
| `writeSection` | none | Not reached by the CLI (see the file note). |
| `appStateToYaml` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/app-state.ts` to no Zig file

Not reached by the CLI: the desktop and mobile apps' settings and remembered interface state (config.yaml and the app state). The CLI keeps its settings in databases.toml and state.yaml.

| TypeScript | Zig | Notes |
|---|---|---|
| `loadAppState` | none | Not reached by the CLI (see the file note). |
| `updateAppState` | none | Not reached by the CLI (see the file note). |
| `asFolderStateKey` | none | Not reached by the CLI (see the file note). |
| `getFolderPath` | none | Not reached by the CLI (see the file note). |
| `updateFolderPath` | none | Not reached by the CLI (see the file note). |
| `updateLastFolder` | none | Not reached by the CLI (see the file note). |
| `updateLastDownloadFolder` | none | Not reached by the CLI (see the file note). |
| `getRecentSearches` | none | Not reached by the CLI (see the file note). |
| `addRecentSearch` | none | Not reached by the CLI (see the file note). |
| `removeRecentSearch` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/apply-database-ops.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `groupOpsByDatabaseId` | none | Not reached by the CLI (see the file note). |
| `applyMetadataDatabaseOps` | none | Not reached by the CLI (see the file note). |
| `applyDatabaseOps` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/asset-server-core.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `createAssetServerCore` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/asset-server-routes.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `attachAssetServerRoutes` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/asset-server.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `sleep` | none | Not reached by the CLI (see the file note). |
| `assetServerHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/auto-import-desktop.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `foldersAsSources` | none | Not reached by the CLI (see the file note). |
| `getDefaultDatabasePath` | none | Not reached by the CLI (see the file note). |
| `planDesktopAutoImport` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/auto-import-queue.ts` to no Zig file

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/node-api/src/lib/auto-import-scanner.ts` to `packages-zig/node-api-zig/src/lib/auto-import-scanner.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `AutoImportScanner` | `AutoImportScanner` |  |
| `AutoImportScanner.constructor` | `AutoImportScanner.init` |  |
| `AutoImportScanner.scan` | `AutoImportScanner.scan` |  |
| `AutoImportScanner.release` | `AutoImportScanner.release` |  |
| `AutoImportScanner.progress` | `AutoImportScanner.progress` |  |
| `AutoImportScanner.pushItem` | `AutoImportScanner.pushItem` |  |
| `AutoImportScanner.listSourcePage` | `AutoImportScanner.listSourcePage` |  |
| `AutoImportScanner.queueNeedsAPage` | `AutoImportScanner.queueNeedsAPage` |  |
| `AutoImportScanner.fetchAPage` | `AutoImportScanner.fetchAPage` |  |
| `AutoImportScanner.hasNothingLeftToPush` | `AutoImportScanner.hasNothingLeftToPush` |  |
| none | `IAutoImportScannerProgress` | The TypeScript interface of the same name, as a struct. |
| none | `IsCancelledFn` | The `isCancelled` field type of IAutoImportScannerDeps, as a closure. |
| none | `SleepFn` | The `sleep` field type of IAutoImportScannerDeps, as a closure. |
| none | `AlreadyImportedContentHashFn` | The `alreadyImportedContentHash` field type of IAutoImportScannerDeps, as a closure. |
| none | `OnLibraryWalkedFn` | The `onLibraryWalked` field type of IAutoImportScannerDeps, as a closure. |
| none | `OnAutoImportProgressFn` | The `onProgress` field type of IAutoImportScannerDeps, as a closure. |
| none | `LogInfoFn` | The `logInfo` field type of IAutoImportScannerDeps, as a closure. |
| none | `IAutoImportScannerDeps` | The TypeScript interface of the same name, as a struct. |
| none | `PushedItemScan` | The `async result => { ... }` arrow function `pushItem` passes to `scanPath`, and the `pushed` variable it sets. |
| none | `PushedItemScan.visit` | The body of that arrow function. |
| none | `AutoImportScanner.importScanner` | Zig plumbing: returns the interface view of the struct (a TypeScript class implements the interface directly). |
| none | `AutoImportScanner.scanErased` | Zig plumbing: the type-erased vtable entry of the interface method. |
| none | `AutoImportScanner.releaseErased` | Zig plumbing: the type-erased vtable entry of the interface method. |
| none | `AutoImportScanner.isCancelled` | `deps.isCancelled()`. |

#### `packages/node-api/src/lib/check-database-exists.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `checkDatabaseExistsHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/check.ts` to `packages-zig/node-api-zig/src/lib/check.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `checkPaths` | `checkPaths` |  |
| none | `CheckPathsProgressCallback` | The TypeScript type of the same name, as a closure. |
| none | `CheckPathsState` | The variables checkPaths' callbacks close over. |
| none | `CheckPathsState.onTaskComplete` | The arrow function passed to `queue.onTaskComplete`. |
| none | `CheckPathsState.visitFile` | The first arrow function passed to `scanPaths`. |
| none | `CheckPathsState.onScanProgress` | The second arrow function passed to `scanPaths`. |

#### `packages/node-api/src/lib/check.worker.ts` to `packages-zig/node-api-zig/src/lib/check.worker.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `checkFileHandler` | `checkFileHandler` |  |
| none | `ICheckFileData` | The TypeScript interface of the same name, as a struct. |
| none | `ICheckHashedFile` | The TypeScript interface of the same name, as a struct. |
| none | `ICheckFileResult` | The TypeScript interface of the same name, as a struct. |
| none | `resultToJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |

#### `packages/node-api/src/lib/cleanup-sources.worker.ts` to `packages-zig/node-api-zig/src/lib/cleanup-sources.worker.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `cleanupSourcesHandler` | `cleanupSourcesHandler` |  |
| none | `registerFolderMediaSourceBuilder` | The module-level `registerMediaSourceBuilder("folder", ...)` call, which runs when TypeScript loads the module; initTaskHandlers calls it. |
| none | `ICleanupSourcesData` | The TypeScript interface of the same name, as a struct. |
| none | `ICleanupSourcesResult` | The TypeScript interface of the same name, as a struct. |
| none | `RemoveSessionTempDirOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `RemoveSessionTempDirOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `isInTheDatabase` | The nested function `isInTheDatabase` of cleanupSourcesHandler. |
| none | `resultToJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |

#### `packages/node-api/src/lib/config-file.ts` to no Zig file

Not reached by the CLI: the desktop and mobile apps' settings and remembered interface state (config.yaml and the app state). The CLI keeps its settings in databases.toml and state.yaml.

| TypeScript | Zig | Notes |
|---|---|---|
| `getConfigPath` | none | Not reached by the CLI (see the file note). |
| `loadConfigFile` | none | Not reached by the CLI (see the file note). |
| `saveConfigFile` | none | Not reached by the CLI (see the file note). |
| `updateConfigFile` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/config-format.ts` to no Zig file

Not reached by the CLI: the desktop and mobile apps' settings and remembered interface state (config.yaml and the app state). The CLI keeps its settings in databases.toml and state.yaml.

| TypeScript | Zig | Notes |
|---|---|---|
| `yamlSourceToRawSource` | none | Not reached by the CLI (see the file note). |
| `sourceToYaml` | none | Not reached by the CLI (see the file note). |
| `isSection` | none | Not reached by the CLI (see the file note). |
| `yamlToAutoImportFile` | none | Not reached by the CLI (see the file note). |
| `yamlToSyncFile` | none | Not reached by the CLI (see the file note). |
| `yamlToConfigFile` | none | Not reached by the CLI (see the file note). |
| `configFileToYaml` | none | Not reached by the CLI (see the file note). |
| `defaultConfigFile` | none | Not reached by the CLI (see the file note). |
| `sectionsPresent` | none | Not reached by the CLI (see the file note). |
| `parseConfigYamlChecked` | none | Not reached by the CLI (see the file note). |
| `parseConfigYaml` | none | Not reached by the CLI (see the file note). |
| `buildConfigYaml` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/config.worker.ts` to no Zig file

Not reached by the CLI: the desktop and mobile apps' settings and remembered interface state (config.yaml and the app state). The CLI keeps its settings in databases.toml and state.yaml.

| TypeScript | Zig | Notes |
|---|---|---|
| `readConfigFromStorage` | none | Not reached by the CLI (see the file note). |
| `readConfigHandler` | none | Not reached by the CLI (see the file note). |
| `writeConfigHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/consolidate-database.worker.ts` to `packages-zig/node-api-zig/src/lib/consolidate-database.worker.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `consolidateDatabaseHandler` | `consolidateDatabaseHandler` |  |
| none | `IConsolidateDatabaseData` | The TypeScript interface of the same name, as a struct. |
| none | `IConsolidateProgressMessage` | The TypeScript interface of the same name, as a struct. |
| none | `ProgressMessageSender` | The `(pushed, total) => { ... }` arrow function passed to consolidateDatabases. |
| none | `ProgressMessageSender.send` | The body of that arrow function. |
| none | `toJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |

#### `packages/node-api/src/lib/consolidate.ts` to `packages-zig/node-api-zig/src/lib/consolidate.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `originalHashes` | `originalHashes` |  |
| `planConsolidation` | `planConsolidation` |  |
| `copyAssetFile` | `copyAssetFile` |  |
| `consolidateDatabases` | `consolidateDatabases` |  |
| `findLeaf` | `findLeaf` |  |
| none | `IConsolidationPlan` | The TypeScript interface of the same name, as a struct. |
| none | `hexOf` | `contentHash.toString("hex")`. |
| none | `IConsolidationResult` | The TypeScript interface of the same name, as a struct. |
| none | `IConsolidationProgressCallback` | The TypeScript interface of the same name, as a struct. |
| none | `IConsolidationProgressCallback.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `pushAbsentAssets` | The body of the first `try` block of consolidateDatabases (under the remote's write lock), a function so the lock can be released after it whatever it returns. |
| none | `joinAsPartialReplica` | The body of the second `try` block of consolidateDatabases (under the local write lock). |

#### `packages/node-api/src/lib/create-auto-import-scanner.ts` to `packages-zig/node-api-zig/src/lib/create-auto-import-scanner.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `createAutoImportScanner` | `createAutoImportScanner` |  |
| none | `buildFolderMediaSource` | The arrow function the module registers as the folder media source builder. |
| none | `registerFolderMediaSourceBuilder` | The module-level `registerMediaSourceBuilder("folder", ...)` call, which runs when TypeScript loads the module; initTaskHandlers calls it. |
| none | `ICreateAutoImportScannerOptions` | The TypeScript interface of the same name, as a struct. |
| none | `AutoImportScannerCallbacks` | The variables the nested functions of createAutoImportScanner close over (`options`, `cacheEntriesRecorded`). |
| none | `AutoImportScannerCallbacks.alreadyImportedContentHash` | The nested function `alreadyImportedContentHash`. |
| none | `AutoImportScannerCallbacks.onLibraryWalked` | The nested function `onLibraryWalked`. |
| none | `AutoImportScannerCallbacks.isCancelled` | The arrow function `() => options.context.isCancelled()`. |
| none | `AutoImportScannerCallbacks.sleepFor` | The arrow function `milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))`. |
| none | `AutoImportScannerCallbacks.logInfo` | The arrow function `message => log.info(message)`. |
| none | `SaveHashCacheOperation` | The arrow function `() => localHashCache.save()` passed to swallowError and retryOrLog (shared by check, import-assets and create-auto-import-scanner). |
| none | `SaveHashCacheOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |

#### `packages/node-api/src/lib/create-database.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `createDatabaseHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/create-default-database.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `createDefaultDatabaseHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/database-cache-dir.ts` to `packages-zig/node-api-zig/src/lib/database-cache-dir.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `getDatabaseCacheDir` | `getDatabaseCacheDir` |  |
| `getImportRecordPath` | `getImportRecordPath` |  |

#### `packages/node-api/src/lib/databases-config-format.ts` to `packages-zig/node-api-zig/src/lib/databases-config-format.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `tomlEntryToDatabaseEntry` | `tomlEntryToDatabaseEntry` |  |
| `databaseEntryToToml` | `databaseEntryToToml` |  |
| none | `IDatabaseEntry` | The TypeScript interface of the same name, as a struct. |
| none | `stringProperty` | Reading a string property of the parsed TOML (`tomlEntry.origin` and so on); absent or not a string is null. |

#### `packages/node-api/src/lib/databases-config.ts` to `packages-zig/node-api-zig/src/lib/databases-config.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `getDatabasesConfigPath` | `getDatabasesConfigPath` |  |
| `tomlToDatabasesConfig` | `tomlToDatabasesConfig` |  |
| `databasesConfigToToml` | `databasesConfigToToml` |  |
| `namesMatch` | `namesMatch` |  |
| `loadDatabasesConfig` | `loadDatabasesConfig` |  |
| `updateDatabasesConfig` | `updateDatabasesConfig` |  |
| `getDatabases` | `getDatabases` |  |
| `findDatabase` | `findDatabase` |  |
| `addDatabaseEntry` | `addDatabaseEntry` |  |
| `updateDatabaseEntry` | `updateDatabaseEntry` |  |
| `removeDatabaseEntry` | `removeDatabaseEntry` |  |
| `getRecentDatabases` | none | Not reached by the CLI: only the desktop app keeps a recent list. |
| `removeRecentDatabaseName` | none | Not reached by the CLI: only the desktop app keeps a recent list. |
| `markDatabaseOpened` | none | Not reached by the CLI: only the desktop app keeps a recent list. |
| `getLastDatabase` | none | Not reached by the CLI: only the desktop app reopens the last database. |
| `setLastDatabase` | none | Not reached by the CLI: only the desktop app reopens the last database. |
| none | `IDatabasesConfig` | The TypeScript interface of the same name, as a struct. |
| none | `DATABASES_FILE` | The module constant DATABASES_FILE, worked out on each call (TypeScript works it out when the module loads). |
| none | `arrayProperty` | `Array.isArray(toml.x) ? toml.x : ...`. |
| none | `stringItems` | The `recent_database_names` array. TypeScript keeps it as it is; Zig keeps its strings (see "JavaScript behaviour not emulated"). |
| none | `DatabasesConfigTomlMutator` | The arrow function updateDatabasesConfig passes to updateToml. |
| none | `AddDatabaseEntryMutator` | The arrow function addDatabaseEntry passes to updateDatabasesConfig. |
| none | `AddDatabaseEntryMutator.run` | The body of that arrow function. |
| none | `UpdateDatabaseEntryMutator` | The arrow function updateDatabaseEntry passes to updateDatabasesConfig. |
| none | `UpdateDatabaseEntryMutator.run` | The body of that arrow function. |
| none | `RemoveDatabaseEntryMutator` | The arrow function removeDatabaseEntry passes to updateDatabasesConfig. |
| none | `RemoveDatabaseEntryMutator.run` | The body of that arrow function. |

#### `packages/node-api/src/lib/databases-config.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `readDatabasesConfigHandler` | none | Not reached by the CLI (see the file note). |
| `writeDatabasesConfigHandler` | none | Not reached by the CLI (see the file note). |
| `isTestDatabaseName` | none | Not reached by the CLI (see the file note). |
| `registerDatabaseInConfig` | none | Not reached by the CLI (see the file note). |
| `buildDatabasesConfigToml` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/decrypt.ts` to `packages-zig/node-api-zig/src/lib/decrypt.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `decryptFile` | `decryptFile` |  |
| `decryptableFiles` | `decryptableFiles` |  |
| `decrypt` | `decrypt` |  |
| none | `IDecryptProgress` | The TypeScript interface of the same name, as a struct. |
| none | `IDecryptProgress.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `IDecryptResult` | The TypeScript interface of the same name, as a struct. |
| none | `DecryptableFilesIterator` | The async generator decryptableFiles, as an iterator. |
| none | `DecryptableFilesIterator.next` | One step of that generator. |
| none | `DecryptFileTask` | The `async fileName => { ... }` arrow function mapped over a batch for `Promise.all`; the batch runs concurrently and the tree update is guarded by a mutex. |
| none | `DecryptFileTask.run` | The body of that arrow function. |

#### `packages/node-api/src/lib/encrypt.ts` to `packages-zig/node-api-zig/src/lib/encrypt.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `encryptFile` | `encryptFile` |  |
| `encryptableFiles` | `encryptableFiles` |  |
| `encrypt` | `encrypt` |  |
| none | `IEncryptProgress` | The TypeScript interface of the same name, as a struct. |
| none | `IEncryptProgress.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `IEncryptResult` | The TypeScript interface of the same name, as a struct. |
| none | `EncryptableFilesIterator` | The async generator encryptableFiles, as an iterator. |
| none | `EncryptableFilesIterator.next` | One step of that generator. |
| none | `EncryptFileTask` | The `async fileName => { ... }` arrow function mapped over a batch for `Promise.all`; the batch runs concurrently and the tree update is guarded by a mutex. |
| none | `EncryptFileTask.run` | The body of that arrow function. |

#### `packages/node-api/src/lib/evict-originals.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `indexTreeFiles` | none | Not reached by the CLI (see the file note). |
| `getDeviceFreeBytes` | none | Not reached by the CLI (see the file note). |
| `buildEvictionCandidates` | none | Not reached by the CLI (see the file note). |
| `deleteIfPresent` | none | Not reached by the CLI (see the file note). |
| `evictOriginalsHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/file-scanner.ts` to `packages-zig/node-api-zig/src/lib/file-scanner.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `shouldIncludeFile` | `shouldIncludeFile` |  |
| `walkDirectory` | `walkDirectory` |  |
| `formatZipDisplayPath` | `formatZipDisplayPath` |  |
| `constructLogicalPath` | `constructLogicalPath` |  |
| `formatZipProgressPath` | `formatZipProgressPath` |  |
| `scanZipFile` | `scanZipFile` |  |
| `scanDirectory` | `scanDirectory` |  |
| `scanPathInternal` | `scanPathInternal` |  |
| `scanPaths` | `scanPaths` |  |
| `scanPath` | `scanPath` |  |
| none | `IFileStat` | The TypeScript interface of the same name, as a struct. |
| none | `ScannerState` | The TypeScript interface of the same name (the generator matches only exported functions and classes). |
| none | `ScanProgressCallback` | The TypeScript type of the same name, as a closure. |
| none | `ScanProgressCallback.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `FileScannedResult` | The TypeScript interface of the same name. |
| none | `SimpleFileCallback` | The TypeScript type of the same name, as a closure. |
| none | `SimpleFileCallback.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `ScannerOptions` | The TypeScript interface of the same name. A pattern is the literal text the TypeScript regular expression matches anywhere in a name. |
| none | `IOrderedFile` | The TypeScript interface of the same name, as a struct. |
| none | `getMimeType` | `mime.getType(path)`, through third-party/mime (replaces the `mime` npm package). |
| none | `IDirectoryEntry` | The TypeScript interface of the same name, as a struct. |
| none | `entryLessThan` | The sort comparator `a.name.localeCompare(b.name, undefined, { numeric: true })`. |
| none | `OrderedFileVisitor` | Zig plumbing: the body of the `for await` loop over the walkDirectory generator, as a closure walkDirectory calls. |
| none | `isIgnored` | The `isIgnored` arrow function inside walkDirectory. |
| none | `truncateUtf16` | `rootZipName.substring(0, 50)` on UTF-16 code units; a cut through a surrogate pair ends in U+FFFD, as the lone surrogate is written. |
| none | `statPath` | Replaces `fs.stat`, with Node's message for a missing path. |
| none | `statModifiedTime` | `stats.mtime`: whole milliseconds, truncated towards zero as the Date constructor truncates mtimeMs. |
| none | `extractNestedZip` | The body of scanZipFile's `try` block for a nested zip, a function so its errors can be caught. |
| none | `extractFile` | The body of scanZipFile's `try` block for a media file, a function so its errors can be caught. |
| none | `DirectoryScan` | The variables the body of scanDirectory's `for await` loop uses. |
| none | `DirectoryScan.visitOrderedFile` | The body of that loop. |

#### `packages/node-api/src/lib/folder-media-source.ts` to `packages-zig/node-api-zig/src/lib/folder-media-source.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `FolderMediaSource` | `FolderMediaSource` |  |
| `FolderMediaSource.constructor` | `FolderMediaSource.init` |  |
| `FolderMediaSource.scan` | `FolderMediaSource.scan` |  |
| `FolderMediaSource.listPage` | `FolderMediaSource.listPage` |  |
| `FolderMediaSource.openItem` | `FolderMediaSource.openItem` |  |
| `FolderMediaSource.closeItem` | `FolderMediaSource.closeItem` |  |
| `FolderMediaSource.deleteItems` | `FolderMediaSource.deleteItems` |  |
| none | `IScannedItem` | The TypeScript interface of the same name, as a struct. |
| none | `scannedItemLessThan` | The sort comparator `left.item.sourceId.localeCompare(right.item.sourceId)`. |
| none | `FolderScan` | The `async result => { ... }` arrow function FolderMediaSource.scan passes to scanPaths, and what it closes over. |
| none | `FolderScan.visit` | The body of that arrow function. |
| none | `FolderMediaSource.mediaSource` | Zig plumbing: returns the interface view of the struct (a TypeScript class implements the interface directly). |
| none | `FolderMediaSource.listPageErased` | Zig plumbing: the type-erased vtable entry of the interface method. |
| none | `FolderMediaSource.openItemErased` | Zig plumbing: the type-erased vtable entry of the interface method. |
| none | `FolderMediaSource.closeItemErased` | Zig plumbing: the type-erased vtable entry of the interface method. |
| none | `FolderMediaSource.deleteItemsErased` | Zig plumbing: the type-erased vtable entry of the interface method. |
| none | `FolderMediaSource.findSourceIdIndex` | `scannedItems.findIndex(scannedItem => scannedItem.item.sourceId === cursor)`. |

#### `packages/node-api/src/lib/get-database-summary.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `getDatabaseSummaryHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/get-import-record.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `getImportRecordHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/hash-cache.ts` to `packages-zig/node-api-zig/src/lib/hash-cache.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `isUpdateContentionError` | `isUpdateContentionError` |  |
| `getHashCacheDir` | `getHashCacheDir` |  |
| `HashCache` | `HashCache` |  |
| `HashCache.constructor` | `HashCache.init` |  |
| `HashCache.normalizeKey` | `HashCache.normalizeKey` |  |
| `HashCache.entrySize` | `HashCache.entrySize` |  |
| `HashCache.readAssetId` | `HashCache.readAssetId` |  |
| `HashCache.writeAssetId` | `HashCache.writeAssetId` |  |
| `HashCache.computeChecksum` | `HashCache.computeChecksum` |  |
| `HashCache.decodeEntries` | `HashCache.decodeEntries` |  |
| `HashCache.encodeEntries` | `HashCache.encodeEntries` |  |
| `HashCache.load` | `HashCache.load` |  |
| `HashCache.initializeFreshCache` | `HashCache.initializeFreshCache` |  |
| `HashCache.adoptEntries` | `HashCache.adoptEntries` |  |
| `HashCache.createLookupTable` | `HashCache.createLookupTable` |  |
| `HashCache.ensureCapacity` | `HashCache.ensureCapacity` |  |
| `HashCache.save` | `HashCache.save` |  |
| `HashCache.findEntryOffset` | `HashCache.findEntryOffset` |  |
| `HashCache.getEntryOffsetByIndex` | `HashCache.getEntryOffsetByIndex` |  |
| `HashCache.getHash` | `HashCache.getHash` |  |
| `HashCache.addHash` | `HashCache.addHash` |  |
| `HashCache.addSourceHash` | `HashCache.addSourceHash` |  |
| `HashCache.upsertHash` | `HashCache.upsertHash` |  |
| `HashCache.setAssetId` | `HashCache.setAssetId` |  |
| `HashCache.removeSourceEntriesNotIn` | `HashCache.removeSourceEntriesNotIn` |  |
| `HashCache.removeHash` | `HashCache.removeHash` |  |
| `HashCache.getEntryCount` | `HashCache.getEntryCount` |  |
| `HashCache.getAllEntries` | `HashCache.getAllEntries` |  |
| `loadSharedHashCache` | `loadSharedHashCache` |  |
| `forgetSharedHashCaches` | `forgetSharedHashCaches` |  |
| none | `IHashCacheEntry` | The TypeScript interface of the same name, as a struct. |
| none | `ICachedHash` | The TypeScript interface of the same name, as a struct. |
| none | `IHashCacheListing` | The TypeScript interface of the same name, as a struct. |
| none | `IHashToCache` | The TypeScript interface of the same name, as a struct. |
| none | `readUInt32LE` | Replaces Node's `buf.readUInt32LE`. |
| none | `writeUInt32LE` | Replaces Node's `buf.writeUInt32LE`. |
| none | `readUInt48LE` | Replaces Node's `buf.readUIntLE(offset, 6)`. |
| none | `writeUInt48LE` | Replaces Node's `buf.writeUIntLE(value, offset, 6)`, with its RangeError. |
| none | `IDecodedEntries` | The TypeScript interface of the same name, as a struct. |
| none | `HashCache.deinit` | Zig plumbing: frees what the struct owns (garbage collected in TypeScript). |
| none | `HashCache.clearPendingUpserts` | Zig plumbing: `pendingUpserts.clear()`, freeing the keys. |
| none | `HashCache.clearPendingRemovals` | Zig plumbing: `pendingRemovals.clear()`, freeing the keys. |
| none | `HashCache.setPendingUpsert` | Zig plumbing: `pendingUpserts.set(key, entry)`, copying the key and asset id. |
| none | `HashCache.deletePendingUpsert` | Zig plumbing: `pendingUpserts.delete(key)`. |
| none | `HashCache.deletePendingRemoval` | Zig plumbing: `pendingRemovals.delete(key)`. |
| none | `HashCache.addPendingRemoval` | Zig plumbing: `pendingRemovals.add(key)`. |
| none | `HashCache.loadFrom` | The body of load's `try` block, a function so its errors can be caught. |
| none | `HashCache.entryLessThan` | The sort comparator `first.key.localeCompare(second.key)`. |
| none | `HashCache.keyAt` | `this.buffer.toString('utf8', ...)` of an entry's key, inline in TypeScript. |
| none | `ILoadedHashCache` | The TypeScript interface of the same name, as a struct. |

#### `packages/node-api/src/lib/hash-file.worker.ts` to `packages-zig/node-api-zig/src/lib/hash-file.worker.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `hashFileHandler` | `hashFileHandler` |  |
| none | `IHashFileData` | The TypeScript interface of the same name, as a struct. |
| none | `IHashFileResult` | The TypeScript interface of the same name, as a struct. |
| none | `dateNow` | `Date.now()`. |

#### `packages/node-api/src/lib/hash.ts` to `packages-zig/node-api-zig/src/lib/hash.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `computeHash` | `computeHash` |  |
| `getNativeFileHasher` | `getNativeFileHasher` |  |
| `computeFileHash` | `computeFileHash` |  |
| `computeAssetHash` | `computeAssetHash` |  |
| `getHashFromCache` | `getHashFromCache` |  |
| `validateAndHash` | `validateAndHash` |  |
| none | `NativeFileHasher` | The `(filePath: string) => Buffer` type of the native hasher, as a closure. There is none in the CLI. |

#### `packages/node-api/src/lib/image.ts` to `packages-zig/node-api-zig/src/lib/image.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `parseExifDate` | `parseExifDate` |  |
| `pickExifDate` | `pickExifDate` |  |
| `getImageDetails` | `getImageDetails` |  |
| `dimensionsFromExif` | `dimensionsFromExif` |  |
| `getImageMetadata` | `getImageMetadata` |  |
| `resizeImage` | `resizeImage` |  |
| `transformImage` | `transformImage` |  |
| none | `digitsAt` | The `(\d{2})` groups of EXIF_DATE_PATTERN and their `parseInt(..., 10)`. |
| none | `dateNow` | `Date.now()`. |
| none | `IImageMetadata` | The TypeScript interface of the same name, as a struct. |
| none | `parseExif` | `exifParser.create(fileData)`, `enableSimpleValues(false)` and `parse()`, through third-party/exif-parser (replaces the `exif-parser` npm package). |
| none | `isTruthy` | JavaScript truthiness of an EXIF tag value. |
| none | `readImageMetadata` | The body of getImageMetadata's `try` block, a function so its errors can be caught. |
| none | `locationJson` | `JSON.stringify(coordinates)`. |
| none | `writeJsonNumber` | A number as JSON.stringify writes it. |
| none | `jsRound` | `Math.round`. |

#### `packages/node-api/src/lib/import-assets.worker.ts` to `packages-zig/node-api-zig/src/lib/import-assets.worker.zig`

The nested functions and closures of importAssetsHandler (flushImportRecord, recordImportOutcome, flushCacheIfDue, hasWorkInFlight, cacheKeyOfPath, releaseFile, dispatchChildTasks, processPendingDatabaseUpdates, the throttled queue processor, recordChildTaskOutcome, onScannerProgress, sendImportProgress and the two scanPaths callbacks) are the methods of `ImportRun`, whose fields are the variables they close over. `countedStorage`, the Proxy that counts what the database writes, is not ported: its counters are never read.

| TypeScript | Zig | Notes |
|---|---|---|
| `shouldWriteDatabaseBatch` | `shouldWriteDatabaseBatch` |  |
| `describeImportProgress` | `describeImportProgress` |  |
| `importAssetsHandler` | `importAssetsHandler` |  |
| none | `IImportAssetsData` | The TypeScript interface of the same name, as a struct. |
| none | `IImportOptions` | The TypeScript interface of the same name, as a struct. |
| none | `IImportOptions.toJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `importAssetsResultToJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `toJsonValue` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `IPendingDatabaseUpdate` | The TypeScript interface of the same name, as a struct. |
| none | `FlushImportRecordOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `FlushImportRecordOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ReleaseFileOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ReleaseFileOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `RemoveSessionTempDirOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `RemoveSessionTempDirOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ImportRun` | The local variables of importAssetsHandler that its nested functions close over. |
| none | `ImportRun.lock` | Zig plumbing: TypeScript's callbacks run one at a time on the event loop; Zig's task callbacks run on worker threads, so they take this lock. |
| none | `ImportRun.unlock` | Zig plumbing: see `ImportRun.lock`. |
| none | `ImportRun.sleepUnlocked` | `await sleep(milliseconds)`, which lets the event loop run the callbacks; Zig releases the lock while it sleeps. |
| none | `ImportRun.nowIsoString` | `new Date(timestampProvider.dateNow()).toISOString()`. |
| none | `ImportRun.sendStringMessage` | `context.sendMessage({ ... })` for a message of string fields. |
| none | `ImportRun.flushImportRecord` | The nested function `flushImportRecord`. |
| none | `ImportRun.recordImportOutcome` | The nested function `recordImportOutcome`. |
| none | `ImportRun.flushCacheIfDue` | The nested function `flushCacheIfDue`. |
| none | `ImportRun.hasWorkInFlight` | The nested function `hasWorkInFlight`. |
| none | `ImportRun.filesAwaitingHashCount` | `filesAwaitingHash.length` (the array is consumed from a head index instead of `shift()`). |
| none | `ImportRun.assetsAwaitingUploadCount` | `assetsAwaitingUpload.length` (consumed from a head index instead of `shift()`). |
| none | `ImportRun.cacheKeyOfPath` | The nested function `cacheKeyOfPath`. |
| none | `ImportRun.releaseFile` | The nested function `releaseFile`. |
| none | `ImportRun.dispatchChildTasks` | The nested function `dispatchChildTasks`. |
| none | `ImportRun.processPendingDatabaseUpdates` | The nested function `processPendingDatabaseUpdates`, up to its `try` block. |
| none | `ImportRun.writeLockedBatch` | The `try` block of processPendingDatabaseUpdates, a function so the write lock can be released after it whatever it returns. |
| none | `ImportRun.processQueue` | The async arrow function passed to `throttle` (`throttledProcessQueue`). |
| none | `ImportRun.processQueueThrottled` | The `catch` of that arrow function: logs the error. |
| none | `ImportRun.onTaskComplete` | The arrow function passed to `queue.onTaskComplete`. |
| none | `ImportRun.recordChildTaskOutcome` | The nested function `recordChildTaskOutcome`. |
| none | `ImportRun.onScannerProgress` | The nested function `onScannerProgress`. |
| none | `ImportRun.sendImportProgress` | The nested function `sendImportProgress`. |
| none | `ImportRun.visitFile` | The first arrow function passed to `scanner.scan`. |
| none | `ImportRun.onScanProgress` | The second arrow function passed to `scanner.scan`. |
| none | `ImportRun.reportScanProgress` | The body of that arrow function. |
| none | `CaughtUpFlushOperation` | The async arrow function onScannerProgress hands to swallowError when the scanner has caught up. |
| none | `CaughtUpFlushOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `optionalStringsEqual` | `stateBeforeWriting?.lastModifiedAt !== lastModifiedAtWrittenByThisRun`. |
| none | `hexToBuffer` | `Buffer.from(hash, "hex")` of a hash the worker wrote. |
| none | `jsNumber` | The number `filesImported += n` adds to. |
| none | `recordMicro` | `assetData.assetRecord.micro`. |
| none | `isAutoImport` | `data.options?.auto`. |
| none | `runResult` | The `result` object importAssetsHandler returns. |
| none | `loadExistingHashes` | The nested function `loadExistingHashes`. |

#### `packages/node-api/src/lib/import-record-storage.ts` to `packages-zig/node-api-zig/src/lib/import-record-storage.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `loadImportRecord` | `loadImportRecord` |  |
| `recordImports` | `recordImports` |  |
| none | `AddEntriesMutator` | The arrow function `record => addImportEntries(record, newEntries)`. |
| none | `AddEntriesMutator.run` | The body of that arrow function. |
| none | `ParseRecord` | `parseImportRecord` passed as a function value. |
| none | `ParseRecord.run` | Calls parseImportRecord. |
| none | `SerializeRecord` | `serializeImportRecord` passed as a function value. |
| none | `SerializeRecord.run` | Calls serializeImportRecord. |
| none | `UpdateImportRecordOperation` | The async arrow function recordImports passes to swallowError. |
| none | `UpdateImportRecordOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |

#### `packages/node-api/src/lib/import-scanner.ts` to `packages-zig/node-api-zig/src/lib/import-scanner.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IScannedImportFile` | The TypeScript interface of the same name, as a struct. |
| none | `IScannedImportFile.fromScanned` | `{ ...result, cacheIdentity }`. |
| none | `VisitImportFile` | The `(result: IScannedImportFile) => Promise<void>` parameter type of `scan`, as a closure. |
| none | `VisitImportFile.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `IImportScanner` | The TypeScript interface of the same name, as a struct. |
| none | `IImportScanner.scan` | The interface method, dispatched through the vtable. |
| none | `IImportScanner.release` | The interface method, dispatched through the vtable. |

#### `packages/node-api/src/lib/import.ts` to `packages-zig/node-api-zig/src/lib/import.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `addPaths` | `addPaths` |  |
| none | `AddPathsProgressCallback` | The TypeScript type of the same name, as a closure. |
| none | `AddPathsState` | The variables addPaths' callbacks close over. |
| none | `AddPathsState.onAnyTaskMessage` | The arrow function passed to `queue.onAnyTaskMessage`. |
| none | `AddPathsState.shutdownOnTermination` | The arrow function passed to `registerTerminationCallback`. |

#### `packages/node-api/src/lib/lan-share.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `watchForCancellation` | none | Not reached by the CLI (see the file note). |
| `receiveShareHandler` | none | Not reached by the CLI (see the file note). |
| `findReceiverHandler` | none | Not reached by the CLI (see the file note). |
| `sendPayloadHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/lazy-origin-storage.ts` to `packages-zig/node-api-zig/src/lib/lazy-origin-storage.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `LazyOriginStorage` | `LazyOriginStorage` |  |
| `LazyOriginStorage.constructor` | `LazyOriginStorage.init` |  |
| `LazyOriginStorage.location` | none | The getter is the `location` field of the IStorage view. |
| `LazyOriginStorage.isEmpty` | `LazyOriginStorage.isEmpty` |  |
| `LazyOriginStorage.listFiles` | `LazyOriginStorage.listFiles` |  |
| `LazyOriginStorage.listDirs` | `LazyOriginStorage.listDirs` |  |
| `LazyOriginStorage.fileExists` | `LazyOriginStorage.fileExists` |  |
| `LazyOriginStorage.dirExists` | `LazyOriginStorage.dirExists` |  |
| `LazyOriginStorage.info` | `LazyOriginStorage.info` |  |
| `LazyOriginStorage.readableLength` | `LazyOriginStorage.readableLength` |  |
| `LazyOriginStorage.writeStreamHashed` | `LazyOriginStorage.writeStreamHashed` |  |
| `LazyOriginStorage.storedHash` | `LazyOriginStorage.storedHash` |  |
| `LazyOriginStorage.read` | `LazyOriginStorage.read` |  |
| `LazyOriginStorage.write` | `LazyOriginStorage.write` |  |
| `LazyOriginStorage.readStream` | `LazyOriginStorage.readStream` |  |
| `LazyOriginStorage.writeStream` | `LazyOriginStorage.writeStream` |  |
| `LazyOriginStorage.deleteFile` | `LazyOriginStorage.deleteFile` |  |
| `LazyOriginStorage.deleteDir` | `LazyOriginStorage.deleteDir` |  |
| `LazyOriginStorage.copyTo` | `LazyOriginStorage.copyTo` |  |
| `LazyOriginStorage.checkWriteLock` | `LazyOriginStorage.checkWriteLock` |  |
| `LazyOriginStorage.acquireWriteLock` | `LazyOriginStorage.acquireWriteLock` |  |
| `LazyOriginStorage.releaseWriteLock` | `LazyOriginStorage.releaseWriteLock` |  |
| `LazyOriginStorage.refreshWriteLock` | none | Not reached by the CLI: IStorage in storage-zig has no refreshWriteLock (see storage). |
| none | `LazyOriginStorage.storage` | Zig plumbing: the IStorage view of the struct (a TypeScript class implements the interface directly). |
| none | `writeCache` | `this.local.writeStream(filePath, undefined, cacheStream).catch(() => {})`, run concurrently. |
| none | `CachePipe` | Replaces the `cacheStream` PassThrough: a bounded pipe from the tee to the cache write. |
| none | `CachePipe.push` | `cacheStream.write(chunk)`, waiting while the pipe is full (the backpressure `pause`/`drain` gives). |
| none | `CachePipe.finish` | `cacheStream.end()`, or `cacheStream.destroy(err)` when the origin fails. |
| none | `CachePipe.finishReading` | Zig only: the cache write has stopped reading, so the tee stops feeding it (see "Divergences kept"). |
| none | `CachePipe.streamFunction` | The reading end of the pipe, which the cache write reads. |
| none | `TeeStream` | Replaces the `callerStream` PassThrough and the `data`/`end`/`error` handlers on the origin stream. |
| none | `TeeStream.readerFunction` | Zig plumbing: the reader of the stream. |
| none | `TeeStream.destroyFunction` | Zig plumbing: closes the stream and waits for the cache write. |
| none | `TeeStream.streamFunction` | The origin's `data` handler: each chunk goes to the caller and to the cache. |

#### `packages/node-api/src/lib/load-assets.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `loadAssetsHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/manual-import-scanner.ts` to `packages-zig/node-api-zig/src/lib/manual-import-scanner.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `ManualImportScanner` | `ManualImportScanner` |  |
| `ManualImportScanner.constructor` | `ManualImportScanner.init` |  |
| `ManualImportScanner.scan` | `ManualImportScanner.scan` |  |
| `ManualImportScanner.release` | `ManualImportScanner.release` |  |
| none | `ManualImportScanner.importScanner` | Zig plumbing: returns the interface view of the struct (a TypeScript class implements the interface directly). |
| none | `ManualImportScanner.scanErased` | Zig plumbing: the type-erased vtable entry of the interface method. |
| none | `ManualImportScanner.releaseErased` | Zig plumbing: the type-erased vtable entry of the interface method. |
| none | `ManualImportScanner.visitScannedFile` | The arrow function `result => visitFile({ ...result, cacheIdentity: undefined })`. |

#### `packages/node-api/src/lib/media-file-database.ts` to `packages-zig/node-api-zig/src/lib/media-file-database.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `extractDominantColorFromThumbnail` | `extractDominantColorFromThumbnail` |  |
| `createReadme` | `createReadme` |  |
| `createMediaFileDatabase` | `createMediaFileDatabase` |  |
| `createDatabase` | `createDatabase` |  |
| `loadSortIndexes` | `loadSortIndexes` |  |
| `ensureSortIndex` | `ensureSortIndex` |  |
| `getDatabaseSummary` | `getDatabaseSummary` |  |
| `streamAsset` | none | Not reached by the CLI: the desktop asset server and move/save workers. |
| `writeAsset` | none | Not reached by the CLI: the desktop asset server. |
| `writeAssetStream` | none | Not reached by the CLI: the desktop asset server. |
| `writeAssetStreamVerified` | none | Not reached by the CLI: the desktop move-assets worker. |
| `removeAsset` | `removeAsset` |  |
| `isDatabasePartial` | none | Not reached by the CLI: the desktop load-assets worker. |
| `createLazyDatabaseStorage` | none | Not reached by the CLI: desktop workers. `psi export` uses openLazyOriginStorage. |
| `openLazyOriginStorage` | `openLazyOriginStorage` |  |
| `checkDatabaseExists` | none | Not reached by the CLI: desktop workers. |
| none | `ProgressCallback` | The TypeScript type of the same name, as a closure. |
| none | `ProgressCallback.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `DatabaseMode` | The TypeScript type `"full" \| "partial"`, as an enum. |
| none | `IDatabaseSummary` | The TypeScript interface of the same name, as a struct. |
| none | `getFilesImported` | `merkleTree.databaseMetadata?.filesImported \|\| 0` (see "JavaScript behaviour not emulated" for values of the wrong type). |
| none | `isPartialDatabase` | `merkleTree.databaseMetadata?.isPartial === true`. |
| none | `emptyDatabaseMetadata` | The object literal `{ filesImported: 0 }`. |
| none | `copyDatabaseMetadata` | The spread `{ ...databaseMetadata }`. |
| none | `IAddSummary` | The TypeScript interface of the same name, as a struct. |
| none | `IAssetDetailTimings` | The TypeScript interface of the same name, as a struct. |
| none | `IResolution` | The TypeScript interface of the same name, as a struct. |
| none | `IAssetDetails` | The TypeScript interface of the same name, as a struct. |
| none | `IMediaFileDatabase` | The TypeScript interface of the same name, as a struct. |
| none | `EnsureSortIndexOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `GetDatabaseRootHashOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `GetDatabaseRootHashOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `removeAssetUnderLock` | The `try` block of removeAsset, a function so the write lock can be released after it whatever it returns. |
| none | `configOrigin` | `config?.origin`, falsy when absent or empty. |

#### `packages/node-api/src/lib/media-source-registry.ts` to `packages-zig/node-api-zig/src/lib/media-source-registry.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `registerMediaSourceBuilder` | `registerMediaSourceBuilder` |  |
| `clearMediaSourceBuilders` | `clearMediaSourceBuilders` |  |
| `buildMediaSource` | `buildMediaSource` |  |
| `parseCompositeCursor` | none | Not reached by the CLI: the CLI registers only the folder builder, so buildMediaSource never builds more than one source; Zig throws loudly if it would. |
| `CompositeMediaSource` | none | Not reached by the CLI (see parseCompositeCursor). |
| `CompositeMediaSource.constructor` | none | Not reached by the CLI (see parseCompositeCursor). |
| `CompositeMediaSource.listPage` | none | Not reached by the CLI (see parseCompositeCursor). |
| `CompositeMediaSource.openItem` | none | Not reached by the CLI (see parseCompositeCursor). |
| `CompositeMediaSource.closeItem` | none | Not reached by the CLI (see parseCompositeCursor). |
| `CompositeMediaSource.deleteItems` | none | Not reached by the CLI (see parseCompositeCursor). |
| `CompositeMediaSource.childAt` | none | Not reached by the CLI (see parseCompositeCursor). |
| `stampChildIndex` | none | Not reached by the CLI (see parseCompositeCursor). |
| `parseChildIndex` | none | Not reached by the CLI (see parseCompositeCursor). |
| `withSourceId` | none | Not reached by the CLI (see parseCompositeCursor). |
| none | `IMediaSourceBuildOptions` | The TypeScript interface of the same name, as a struct. |
| none | `lockBuilders` | Zig plumbing: the builder map is shared by every worker thread, so it takes a lock; each TypeScript worker has its own. |
| none | `getMediaSourceBuilder` | `mediaSourceBuilders.get(sourceType)`, under the lock. |

#### `packages/node-api/src/lib/media-source.ts` to `packages-zig/node-api-zig/src/lib/media-source.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/node-api/src/lib/move-assets.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `moveAssetsHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/news-fetcher.ts` to `packages-zig/node-api-zig/src/lib/news-fetcher.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `fetchNews` | `fetchNews` |  |
| none | `INewsLink` | The TypeScript interface of the same name, as a struct. |
| none | `INewsItem` | The TypeScript interface of the same name, as a struct. |
| none | `templateText` | `${value}` of a link field. print-notifications.ts prints `${item.link.label}`; Zig turns the fields to text when the feed is read. |
| none | `jsNumberText` | `String(number)`. |
| none | `isTruthy` | JavaScript truthiness of a parsed value. |
| none | `toLink` | `item.link` and `item.action` as print-notifications.ts reads them. |
| none | `isSingleDotSegment` | Part of `fileURLToPath` (the URL parser's `.` segment). |
| none | `isDoubleDotSegment` | Part of `fileURLToPath` (the URL parser's `..` segment). |
| none | `isDriveLetterSegment` | Part of `fileURLToPath` (a Windows drive letter segment). |
| none | `normalizeUrlPath` | Part of `fileURLToPath` (the URL parser's path). |
| none | `percentDecode` | Part of `fileURLToPath` (decoding the path). |
| none | `fileURLToPath` | Replaces `fileURLToPath` from node's `url` module, as Bun runs it. |

#### `packages/node-api/src/lib/news-state.ts` to `packages-zig/node-api-zig/src/lib/news-state.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `loadNewsState` | `loadNewsState` |  |
| `saveNewsState` | `saveNewsState` |  |
| `getShownNewsIds` | `getShownNewsIds` |  |
| `addShownNewsIds` | `addShownNewsIds` |  |
| `getLastShownUpdateVersion` | `getLastShownUpdateVersion` |  |
| `setLastShownUpdateVersion` | `setLastShownUpdateVersion` |  |
| none | `loadNewsStateUnsafe` | The body of loadNewsState's `try` block, a function so its errors can be caught. |
| none | `SaveNewsStateMutator` | The arrow function saveNewsState passes to updateStateFile. |
| none | `SaveNewsStateMutator.run` | The body of that arrow function. |
| none | `AddShownNewsIdsMutator` | The arrow function addShownNewsIds passes to updateStateFile. |
| none | `AddShownNewsIdsMutator.run` | The body of that arrow function. |
| none | `SetLastShownUpdateVersionMutator` | The arrow function setLastShownUpdateVersion passes to updateStateFile. |
| none | `SetLastShownUpdateVersionMutator.run` | The body of that arrow function. |

#### `packages/node-api/src/lib/open-storage.ts` to `packages-zig/node-api-zig/src/lib/open-storage.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `openStorage` | `openStorage` |  |
| none | `IOpenStorageResult` | The TypeScript interface of the same name, as a struct. |

#### `packages/node-api/src/lib/prefetch-database.worker.ts` to `packages-zig/node-api-zig/src/lib/prefetch-database.worker.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `prefetchDatabaseHandler` | `prefetchDatabaseHandler` |  |
| none | `IPrefetchDatabaseData` | The TypeScript interface of the same name, as a struct. |
| none | `IPrefetchDatabaseResult` | The TypeScript interface of the same name, as a struct. |
| none | `configOrigin` | `config?.origin`, falsy when absent or empty. |
| none | `MissingFilesIterator` | The nested async generator `missingFiles`, as an iterator. |
| none | `MissingFilesIterator.next` | One step of that generator. |
| none | `FetchFileTask` | The `async filePath => { ... }` arrow function mapped over a batch for `Promise.all`. |
| none | `FetchFileTask.run` | Runs the arrow function on its own thread and keeps its error. |
| none | `FetchFileTask.fetch` | The body of that arrow function. |
| none | `fetchBatch` | `await Promise.all(batch.map(...))`. |
| none | `prefetchResultToJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |

#### `packages/node-api/src/lib/repair.ts` to `packages-zig/node-api-zig/src/lib/repair.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `repair` | `repair` |  |
| none | `IRepairOptions` | The TypeScript interface of the same name, as a struct. |
| none | `IRepairResult` | The TypeScript interface of the same name, as a struct. |
| none | `reportProgress` | `if (progressCallback) { progressCallback(`...`); }` with a template string. |
| none | `RepairState` | The variables the nested functions of repair close over. |
| none | `RepairState.repairFile` | The nested function `repairFile`: its `catch`. |
| none | `RepairState.tryRepairFile` | The `try` block of repairFile. |
| none | `RepairState.checkFile` | The nested function `checkFile`. |
| none | `RepairState.visitNode` | The async arrow function passed to traverseTreeAsync. |
| none | `InsertOneOperation` | The arrow function `() => metadataCollection.insertOne(minimalRecord)` passed to retry. |
| none | `InsertOneOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `UpdateOneOperation` | The arrow function `() => metadataCollection.updateOne(assetId, { hash })` passed to retry. |
| none | `UpdateOneOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |

#### `packages/node-api/src/lib/replicate-database.ts` to `packages-zig/node-api-zig/src/lib/replicate-database.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `replicateDatabase` | `replicateDatabase` |  |
| none | `ReplicateProgressCallback` | The TypeScript type of the same name, as a closure. |
| none | `ReplicateProgressCallback.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `replicateDatabaseDataToJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `onReplicateProgressMessage` | The arrow function passed to `queue.onTaskMessage("replicate-progress", ...)`. |
| none | `lastPathPart` | `data.destPath.split(/[\\/]/).filter(Boolean).pop()`. |

#### `packages/node-api/src/lib/replicate-database.worker.ts` to `packages-zig/node-api-zig/src/lib/replicate-database.worker.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `replicateDatabaseHandler` | `replicateDatabaseHandler` |  |
| none | `ProgressMessageSender` | The `progressCallback` arrow function of replicateDatabaseHandler. |
| none | `ProgressMessageSender.send` | The body of that arrow function. |
| none | `isTaskCancelled` | The arrow function `() => context.isCancelled()`. |
| none | `replicationResultToJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |

#### `packages/node-api/src/lib/replicate.ts` to `packages-zig/node-api-zig/src/lib/replicate.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `throwIfCancelled` | `throwIfCancelled` |  |
| `replicateFiles` | `replicateFiles` |  |
| `iterateLeaves` | `iterateLeaves` |  |
| `iterateShardDifferences` | `iterateShardDifferences` |  |
| `iterateCollectionDifferences` | `iterateCollectionDifferences` |  |
| `iterateDatabaseDifferences` | `iterateDatabaseDifferences` |  |
| `replicateBsonDatabase` | `replicateBsonDatabase` |  |
| `copyFileIfExists` | `copyFileIfExists` |  |
| `copyBsonMerkleTrees` | `copyBsonMerkleTrees` |  |
| `replicate` | `replicate` |  |
| none | `IReplicationResult` | The TypeScript interface of the same name, as a struct. |
| none | `IsCancelledCallback` | The `isCancelled` option type `() => boolean`, as a closure. |
| none | `IsCancelledCallback.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `IReplicateOptions` | The TypeScript interface of the same name, as a struct. |
| none | `reportProgress` | `if (progressCallback) { progressCallback(`...`); }` with a template string. |
| none | `ReplicateFilesState` | The variables the nested functions of replicateFiles close over. |
| none | `ReplicateFilesState.copyAsset` | The nested function `copyAsset`. |
| none | `ReplicateFilesState.processFile` | The nested function `processFile`. |
| none | `CopyAssetOperation` | The arrow function `() => copyAsset(fileName, sourceFileInfo.hash)` passed to retry. |
| none | `CopyAssetOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `LeafNameIterator` | The generator `iterateLeaves`, as an iterator (depth first, left before right). |
| none | `LeafNameIterator.next` | One step of that generator. |
| none | `ICollectionRecord` | The TypeScript interface of the same name, as a struct. |
| none | `LoadShardMerkleTreeOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `LoadCollectionMerkleTreeOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `LoadDatabaseMerkleTreeOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ShardDifferenceIterator` | The async generator `iterateShardDifferences`, as an iterator. |
| none | `ShardDifferenceIterator.next` | One step of that generator. |
| none | `CollectionDifferenceIterator` | The async generator `iterateCollectionDifferences`, as an iterator. |
| none | `CollectionDifferenceIterator.next` | One step of that generator. |
| none | `DatabaseDifferenceIterator` | The async generator `iterateDatabaseDifferences`, as an iterator. |
| none | `DatabaseDifferenceIterator.next` | One step of that generator. |
| none | `SetInternalRecordOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `SetInternalRecordOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `DeleteOneOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `DeleteOneOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |

#### `packages/node-api/src/lib/reset-app-storage.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `clearDirectory` | none | Not reached by the CLI (see the file note). |
| `resetAppStorageHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/resolve-storage-credentials.ts` to `packages-zig/node-api-zig/src/lib/resolve-storage-credentials.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `parseEncryptionKeyFromVaultValue` | `parseEncryptionKeyFromVaultValue` |  |
| `resolveStorageCredentials` | `resolveStorageCredentials` |  |
| `resolveEncryptionKeyValue` | `resolveEncryptionKeyValue` |  |
| none | `IResolvedStorageCredentials` | The TypeScript interface of the same name, as a struct. |
| none | `isTruthy` | JavaScript truthiness of an optional string. |
| none | `jsonString` | `parsed.region` and the other fields of the parsed vault secret. |

#### `packages/node-api/src/lib/save-asset.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `getAssetStorage` | none | Not reached by the CLI (see the file note). |
| `saveAssetHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/save-assets-batch.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `getAssetStorage` | none | Not reached by the CLI (see the file note). |
| `saveAssetsBatchHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/set-database-origin.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `setDatabaseOriginHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/source-cleanup.ts` to `packages-zig/node-api-zig/src/lib/source-cleanup.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/node-api/src/lib/state-file.ts` to `packages-zig/node-api-zig/src/lib/state-file.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `getStatePath` | `getStatePath` |  |
| `loadStateFile` | `loadStateFile` |  |
| `updateStateFile` | `updateStateFile` |  |
| none | `StateMutator` | The arrow function updateStateFile passes to updateYaml. |

#### `packages/node-api/src/lib/state-format.ts` to `packages-zig/node-api-zig/src/lib/state-format.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `isSection` | `isSection` |  |
| `isUiStateValue` | `isUiStateValue` |  |
| `yamlToStateDesktopSection` | `yamlToStateDesktopSection` |  |
| `yamlToSearchesState` | `yamlToSearchesState` |  |
| `yamlToGalleryState` | `yamlToGalleryState` |  |
| `yamlToNewsFeedItem` | `yamlToNewsFeedItem` |  |
| `yamlToNewsState` | `yamlToNewsState` |  |
| `yamlToUiSection` | `yamlToUiSection` |  |
| `yamlToStateFile` | `yamlToStateFile` |  |
| `newsFeedItemToYaml` | `newsFeedItemToYaml` |  |
| `writeSection` | `writeSection` |  |
| `stateFileToYaml` | `stateFileToYaml` |  |
| `defaultStateFile` | none | Not reached by the CLI: the mobile state worker. |
| `parseStateYamlChecked` | none | Not reached by the CLI: the mobile state worker. |
| `buildStateYaml` | none | Not reached by the CLI: the mobile state worker. |
| none | `INewsFeedItem` | The TypeScript interface of the same name, as a struct. |
| none | `INewsState` | The TypeScript interface of the same name, as a struct. |
| none | `IStateDesktopSection` | The TypeScript interface of the same name, as a struct. |
| none | `ISearchesState` | The TypeScript interface of the same name, as a struct. |
| none | `IGalleryState` | The TypeScript interface of the same name, as a struct. |
| none | `IStateFile` | The TypeScript interface of the same name, as a struct. |
| none | `stringField` | `typeof section.x === "string"`. |
| none | `isNumber` | `typeof value === "number"`. |
| none | `isFiniteNumber` | `typeof value === "number" && Number.isFinite(value)`. |
| none | `stringsOf` | `array.filter(entry => typeof entry === "string")`. |
| none | `stringArray` | A list of strings as a YAML sequence. |

#### `packages/node-api/src/lib/sync-database.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `syncDatabaseHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/sync.ts` to `packages-zig/node-api-zig/src/lib/sync.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `retryOnceNamed` | `retryOnceNamed` |  |
| `syncDatabases` | `syncDatabases` |  |
| `extractAssetId` | `extractAssetId` |  |
| `throughTheDatabases` | `throughTheDatabases` |  |
| `chooseHowToPushBytes` | `chooseHowToPushBytes` |  |
| `pushFiles` | `pushFiles` |  |
| `iterateLeaves` | `iterateLeaves` |  |
| `iterateShardDifferences` | `iterateShardDifferences` |  |
| `iterateCollectionDifferences` | `iterateCollectionDifferences` |  |
| `iterateDatabaseDifferences` | `iterateDatabaseDifferences` |  |
| `syncDatabase` | `syncDatabase` |  |
| none | `ISyncResult` | The TypeScript interface of the same name, as a struct. |
| none | `SyncChangeCallback` | The `onLocalChange` parameter type, as a closure. |
| none | `SyncChangeCallback.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `now` | `Date.now()`. |
| none | `deletedAssetIdsOf` | `new Set(merkleTree?.databaseMetadata?.deletedAssetIds \|\| [])`. A value that is not a list of strings throws, loudly, as not ported. |
| none | `PushFilesOperation` | The arrow function `() => pushFiles(...)` passed to retryOnceNamed. |
| none | `SyncDatabaseOperation` | The arrow function `() => syncDatabase(...)` passed to retryOnceNamed. |
| none | `CommitOperation` | The arrow function `() => bsonDatabase.commit()` passed to retryOnceNamed. |
| none | `StampDatabaseStateOperation` | The arrow function `() => stampDatabaseState(...)` passed to retryOnceNamed. |
| none | `releaseWriteLockAfter` | The `finally { await releaseWriteLock(...) }` of a try block: releases the lock and returns the block's result (an error thrown by the release wins, as it does in `finally`). |
| none | `pullIncomingFiles` | The first `try` block of syncDatabases (under this database's write lock). |
| none | `pushOutgoingFiles` | The second `try` block of syncDatabases (under the origin's write lock). |
| none | `IFileToConsider` | The TypeScript interface of the same name, as a struct. |
| none | `IPushBytes` | The TypeScript interface of the same name, as a struct. |
| none | `PushState` | The variables the nested functions of pushFiles close over. |
| none | `PushState.sayWhereTheTimeWent` | The nested arrow function `sayWhereTheTimeWent` (the JSON is written in the key order JSON.stringify writes it). |
| none | `PushState.copyFile` | The nested arrow function `copyFile`. |
| none | `CopyFileOperation` | The arrow function `() => copyFile(file.name, file.hash)` passed to retry. |
| none | `CopyFileOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `leavesOf` | The leaves of the generator `iterateLeaves`, as a list. |
| none | `ISyncDiffRecord` | The TypeScript interface of the same name, as a struct. |
| none | `DiffVisitor` | Zig plumbing: the consumer of the async generators (the `for await` body of syncDatabase), as a closure the iteration calls, in the same order. |
| none | `DiffVisitor.yield` | `yield` in the generators. |
| none | `withoutDashes` | `recordId.replace(/-/g, '')`. |
| none | `SyncDatabaseState` | The variables the `for await` loop of syncDatabase uses. |
| none | `SyncDatabaseState.visit` | The body of that loop. |

#### `packages/node-api/src/lib/task-handlers.ts` to `packages-zig/node-api-zig/src/lib/task-handlers.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `initTaskHandlers` | `initTaskHandlers` |  |

#### `packages/node-api/src/lib/test-job.worker.ts` to no Zig file

Not reached by the CLI: a desktop or mobile worker task. `initTaskHandlers` registers it in the CLI's worker too, but nothing in the CLI queues it.

| TypeScript | Zig | Notes |
|---|---|---|
| `describeTestJobProgress` | none | Not reached by the CLI (see the file note). |
| `testJobHandler` | none | Not reached by the CLI (see the file note). |

#### `packages/node-api/src/lib/tree.ts` to `packages-zig/node-api-zig/src/lib/tree.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `merkleTreeExists` | `merkleTreeExists` |  |
| `isDatabaseEncrypted` | `isDatabaseEncrypted` |  |
| `saveMerkleTree` | `saveMerkleTree` |  |
| `loadMerkleTree` | `loadMerkleTree` |  |
| `getFilesRootHash` | `getFilesRootHash` |  |
| `getDatabaseContentHash` | `getDatabaseContentHash` |  |
| `buildStampPartial` | `buildStampPartial` |  |
| `stampDatabaseState` | `stampDatabaseState` |  |
| `stampDatabaseModified` | `stampDatabaseModified` |  |
| `stampDatabaseStateLocked` | `stampDatabaseStateLocked` |  |
| `loadCollectionMerkleTree` | `loadCollectionMerkleTree` |  |
| `loadShardMerkleTree` | `loadShardMerkleTree` |  |
| `buildFilesTree` | `buildFilesTree` |  |
| none | `IBuildFilesTreeResult` | The TypeScript interface of the same name, as a struct. |
| none | `IBuildFilesTreeProgress` | The `progressCallback` parameter type, as a closure. |
| none | `IBuildFilesTreeProgress.call` | Zig plumbing: a closure (a context and a function) standing in for the TypeScript function type. |
| none | `matchesDbDirectory` | The ignore pattern `/^\.db(\/\|$)/`. |
| none | `IReadAndHashResult` | The anonymous return type of readAndHash. |
| none | `readAndHash` | The nested function `readAndHash` of buildFilesTree. |
| none | `ReadAndHashTask` | The `({ fileName }) => readAndHash(fileName)` mapped over a batch for `Promise.all`. |
| none | `ReadAndHashTask.run` | Runs readAndHash on its own thread and keeps its error. |

#### `packages/node-api/src/lib/upload-asset.worker.ts` to `packages-zig/node-api-zig/src/lib/upload-asset.worker.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `uploadAssetHandler` | `uploadAssetHandler` |  |
| none | `IUploadAssetData` | The TypeScript interface of the same name, as a struct. |
| none | `IAssetDatabaseData` | The TypeScript interface of the same name, as a struct. |
| none | `IUploadAssetResult` | The TypeScript interface of the same name, as a struct. |
| none | `encodeAssetRecord` | Zig plumbing: the asset record crosses threads as base64 BSON inside the JSON task result, which TypeScript posts as an object. |
| none | `decodeAssetRecord` | Zig plumbing: the other half of encodeAssetRecord. |
| none | `dateNow` | `Date.now()`. |
| none | `toISOString` | `dayjs(time).toISOString()`. |
| none | `WriteFileStreamOperation` | The arrow function `() => storage.writeStream(path, contentType, createReadStream(localPath), length)` passed to retry. |
| none | `ComputeFileHashOperation` | The arrow function `() => computeFileHash(path, getNativeFileHasher())` passed to retry. |
| none | `ReverseGeocodeOperation` | The arrow function `() => reverseGeocode(...)` passed to retry. |
| none | `ReverseGeocodeOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ReadMicroOperation` | The arrow function `() => fs.readFile(assetDetails.microPath)` passed to retry. |
| none | `ReadMicroOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `RemoveDirOperation` | The arrow function `() => remove(assetTempDir)` passed to swallowError. |
| none | `RemoveDirOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `buildLabels` | `data.labels.concat(fileDir.replace(/\\/g, "/").split("/").filter(label => label))`. |
| none | `stringArray` | A list of strings as a BSON array. |
| none | `uploadAndDescribe` | The inner `try` block of uploadAssetHandler, a function so its `catch` can run for any error it returns. |

#### `packages/node-api/src/lib/validation.ts` to `packages-zig/node-api-zig/src/lib/validation.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `validateFile` | `validateFile` |  |
| `validateImage` | `validateImage` |  |
| `validateVideo` | `validateVideo` |  |

#### `packages/node-api/src/lib/verify.ts` to `packages-zig/node-api-zig/src/lib/verify.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `verify` | `verify` |  |
| `verifyDatabaseFiles` | `verifyDatabaseFiles` |  |
| none | `IVerifyOptions` | The TypeScript interface of the same name, as a struct. |
| none | `IVerifyResult` | The TypeScript interface of the same name, as a struct. |
| none | `reportProgress` | `if (progressCallback) { progressCallback(`...`); }` with a template string. |
| none | `VerifyState` | The variables verify's callbacks close over. |
| none | `VerifyState.onTaskComplete` | The arrow function passed to `queue.onTaskComplete`. |
| none | `VerifyState.visitNode` | The async arrow function passed to traverseTreeAsync. |
| none | `IDatabaseFileVerifyError` | The TypeScript interface of the same name, as a struct. |
| none | `IDatabaseFileVerifyResult` | The TypeScript interface of the same name, as a struct. |
| none | `DatabaseFileVerifyState` | The variables the nested functions of verifyDatabaseFiles close over. |
| none | `DatabaseFileVerifyState.addError` | The nested function `addError`. |
| none | `DatabaseFileVerifyState.reportProgress` | The nested function `reportProgress`. |

#### `packages/node-api/src/lib/verify.worker.ts` to `packages-zig/node-api-zig/src/lib/verify.worker.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `verifyFileHandler` | `verifyFileHandler` |  |
| none | `IVerifyFileOptions` | The TypeScript interface of the same name, as a struct. |
| none | `IVerifyFileData` | The TypeScript interface of the same name, as a struct. |
| none | `VerifyFileStatus` | The TypeScript union `"unmodified" \| "modified" \| "removed" \| "new"`, as an enum. |
| none | `IVerifyFileResult` | The TypeScript interface of the same name, as a struct. |
| none | `verifyFileDataToJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `jsonString` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `jsonInteger` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `jsonObject` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `verifyFileDataFromJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `verifyFileResultToJson` | Zig plumbing: task data and task results cross between worker threads as JSON values, which TypeScript posts as objects. |
| none | `toLocaleString` | `date.toLocaleString()` for en-US in UTC (see "JavaScript behaviour not emulated"). |
| none | `ComputeAssetHashOperation` | The async arrow function passed to retry to hash the stored file. |
| none | `ComputeAssetHashOperation.run` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |

#### `packages/node-api/src/lib/video.ts` to `packages-zig/node-api-zig/src/lib/video.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `getVideoDetails` | `getVideoDetails` |  |
| `parseVideoLocation` | `parseVideoLocation` |  |
| none | `dateNow` | `Date.now()`. |
| none | `toISOString` | `date.toISOString()` (and dayjs's), with the RangeError each throws for an Invalid Date. |
| none | `photoTakenTimestamp` | `photoData.photoTakenTime?.timestamp`. |
| none | `isTruthy` | JavaScript truthiness of a number. |
| none | `isValueTruthy` | JavaScript truthiness of a parsed value. |
| none | `jsString` | `String(value)`, which `parseInt` and `String.prototype.match` apply to their argument. |
| none | `jsNumberString` | `String(number)`. |
| none | `matchSignedDecimal` | One `([+-]\d+\.\d+)` group of videoLocationRegex. |

#### `packages/node-api/src/lib/zip-utils.ts` to no Zig file

Not reached by the CLI: only exported from index.ts, and only the desktop asset server calls it. The CLI's zip reading is in file-scanner.ts, through JSZip (third-party/jszip in Zig).

| TypeScript | Zig | Notes |
|---|---|---|
| `extractFileFromZip` | none | Not reached by the CLI (see the file note). |
| `extractNestedZipFromParent` | none | Not reached by the CLI (see the file note). |
| `extractFileFromZipRecursive` | none | Not reached by the CLI (see the file note). |

#### Zig files with no TypeScript file

| Zig file | What it is |
|---|---|
| `packages-zig/node-api-zig/src/lib/fetch.zig` | Replaces the global `fetch` (and `response.ok`, `response.status`, `response.text()`) that news-fetcher.ts calls. |
| `packages-zig/node-api-zig/src/lib/retry-operations.zig` | Zig plumbing: the arrow functions node-api passes to `retry` over and over (`() => storage.info(fileName)`, `() => loadMerkleTree(storage)` and the like), as structs with a `run` method and the `source` text. |
| `packages-zig/node-api-zig/src/lib/third-party/exif-parser/bufferstream.zig` | Replaces the `exif-parser` npm package (lib/parser.js, lib/exif.js, lib/jpeg.js, lib/bufferstream.js, lib/exif-tags.js). |
| `packages-zig/node-api-zig/src/lib/third-party/exif-parser/exif-tags.zig` | Replaces the `exif-parser` npm package (lib/parser.js, lib/exif.js, lib/jpeg.js, lib/bufferstream.js, lib/exif-tags.js). |
| `packages-zig/node-api-zig/src/lib/third-party/exif-parser/exif.zig` | Replaces the `exif-parser` npm package (lib/parser.js, lib/exif.js, lib/jpeg.js, lib/bufferstream.js, lib/exif-tags.js). |
| `packages-zig/node-api-zig/src/lib/third-party/exif-parser/jpeg.zig` | Replaces the `exif-parser` npm package (lib/parser.js, lib/exif.js, lib/jpeg.js, lib/bufferstream.js, lib/exif-tags.js). |
| `packages-zig/node-api-zig/src/lib/third-party/exif-parser/parser.zig` | Replaces the `exif-parser` npm package (lib/parser.js, lib/exif.js, lib/jpeg.js, lib/bufferstream.js, lib/exif-tags.js). |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/compressedObject.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/compressions.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/crc32.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/flate.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/index.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/load.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/object.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/reader/DataReader.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/signature.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/utf8.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/utils.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/zipEntries.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/zipEntry.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/jszip/zipObject.zig` | Replaces the `jszip` npm package (the modules of the same names under lib/), for reading zip files only. |
| `packages-zig/node-api-zig/src/lib/third-party/lodash/debounce.zig` | Replaces `lodash/debounce`, which `lodash/throttle` is built on. |
| `packages-zig/node-api-zig/src/lib/third-party/lodash/throttle.zig` | Replaces `lodash/throttle`. |
| `packages-zig/node-api-zig/src/lib/third-party/mime/Mime.zig` | Replaces the `mime` npm package (Mime.js, index.js and its type lists). |
| `packages-zig/node-api-zig/src/lib/third-party/mime/index.zig` | Replaces the `mime` npm package (Mime.js, index.js and its type lists). |
| `packages-zig/node-api-zig/src/lib/third-party/mime/types/other.zig` | Replaces the `mime` npm package (Mime.js, index.js and its type lists). |
| `packages-zig/node-api-zig/src/lib/third-party/mime/types/standard.zig` | Replaces the `mime` npm package (Mime.js, index.js and its type lists). |

<!-- end tables -->

## node-utils

`packages/node-utils` to `packages-zig/node-utils-zig`. Zig only: `path.zig` (replaces `node:path`),
`process-env.zig` (`process.env`), `toml.zig` (the `smol-toml` npm package) and `yaml.zig` (the `js-yaml` npm package).

<!-- tables: packages/node-utils node-utils.txt -->

#### `packages/node-utils/src/index.ts` to `packages-zig/node-utils-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/node-utils/src/lib/dir.ts` to no Zig file

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| `isDriveRoot` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `ensureParentDirectoryExists` | none | Not reached by the CLI: tree-shaken out of the bundle. |

#### `packages/node-utils/src/lib/exec.ts` to `packages-zig/node-utils-zig/src/lib/exec.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `exec` | `exec` |  |
| `execLogged` | `execLogged` |  |
| none | `ExecResult` | The anonymous `{ stdout, stderr }` type exec returns, named. |
| none | `maxBufferExceeded` | Replaces Bun's `child_process.exec` maxBuffer check: the RangeError `stdout maxBuffer length exceeded` (or stderr). |
| none | `runShell` | Replaces Bun's `child_process.exec` on POSIX: `/bin/sh -c`, stdout and stderr read together, at most maxBuffer (1 MiB) of each. |
| none | `execWindows` | Replaces Bun's `child_process.exec` on Windows. |
| none | `kernel32` | Replaces libuv's process spawning on Windows: the kernel32 functions std.os.windows does not declare. |
| none | `ICmdExeResult` | The TypeScript interface of the same name, as a struct. |
| none | `IChildPipe` | The TypeScript interface of the same name, as a struct. |
| none | `createChildPipe` | Replaces libuv's process spawning on Windows: a stdio pipe of the child. |
| none | `readPipe` | Replaces libuv's process spawning on Windows: reads a stdio pipe of the child, up to maxBuffer. |
| none | `IPipeReader` | The TypeScript interface of the same name, as a struct. |
| none | `IPipeReader.run` | Replaces libuv's process spawning on Windows: reads stderr on its own thread. |
| none | `runCmdExe` | Replaces libuv's process spawning on Windows: `cmd.exe /d /s /c "<command>"` passed verbatim, as Node does. |
| none | `IValidate` | The optional `validate` callback of execLogged, as a context and a function. |
| none | `execLoggedInner` | The body of the `try` block of execLogged. |

#### `packages/node-utils/src/lib/exit-codes.ts` to `packages-zig/node-utils-zig/src/lib/exit-codes.zig`


#### `packages/node-utils/src/lib/find-available-port.ts` to no Zig file

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| `findAvailablePort` | none | Not reached by the CLI: tree-shaken out of the bundle. |

#### `packages/node-utils/src/lib/fs.ts` to `packages-zig/node-utils-zig/src/lib/fs.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `sleep` | `sleep` |  |
| `renameIntoPlace` | `renameIntoPlace` |  |
| `ensureDir` | `ensureDir` |  |
| `ensureFileDir` | `ensureFileDir` | Takes the directory with std.fs.path.dirname where TypeScript uses path.dirname; the two differ only in the root and repeated separators, which name the same directory to create. |
| `pathExists` | `pathExists` |  |
| `remove` | `remove` |  |
| `outputFile` | `outputFile` |  |
| `readJson` | `readJson` |  |
| `readToml` | `readToml` |  |
| `writeToml` | `writeToml` |  |
| `readYaml` | `readYaml` |  |
| `writeYaml` | none | Not reached by the CLI: only the desktop and mobile apps write config.yaml. |
| `updateYaml` | `updateYaml` |  |
| `writeJson` | none | Not reached by the CLI. |
| `readRawFileBytes` | `readRawFileBytes` |  |
| `fileFingerprint` | `fileFingerprint` |  |
| `fingerprintsMatch` | `fingerprintsMatch` |  |
| `tryTakeUpdateLock` | `tryTakeUpdateLock` |  |
| `updateBackoffMs` | `updateBackoffMs` |  |
| `takeUpdateLock` | `takeUpdateLock` |  |
| `updateFileRawOptimistic` | `updateFileRawOptimistic` |  |
| `updateFileOptimistic` | `updateFileOptimistic` |  |
| `updateToml` | `updateToml` |  |
| `updateJson` | none | Not reached by the CLI. |
| `emptyDir` | none | Not reached by the CLI. |
| `copy` | none | Not reached by the CLI. |
| `ensureDirSync` | `ensureDirSync` |  |
| `removeSync` | none | Not reached by the CLI. |
| `copySync` | none | Not reached by the CLI. |
| `getProcessTmpDir` | `getProcessTmpDir` |  |
| `getConfigDir` | `getConfigDir` |  |
| `getCacheDir` | `getCacheDir` |  |
| `readFileHead` | `readFileHead` |  |
| none | `randomUUID` | Replaces `crypto.randomUUID`. |
| none | `YamlParse` | The parse arrow function updateYaml passes to updateFileOptimistic. |
| none | `YamlParse.run` | The parse arrow function updateYaml passes to updateFileOptimistic. |
| none | `YamlSerialize` | The serialize arrow function updateYaml passes to updateFileOptimistic. |
| none | `YamlSerialize.run` | The serialize arrow function updateYaml passes to updateFileOptimistic. |
| none | `IFileFingerprint` | The TypeScript interface of the same name, as a struct. |
| none | `removeFileForce` | Replaces `fs.rm(path, { force: true })` for a file. |
| none | `mathRandom` | Replaces `Math.random`. |
| none | `updateFileRawAttempt` | The body of the `try` block of updateFileRawOptimistic; the `finally` releasing the lock follows the call. |
| none | `OptimisticMutator` | The arrow function updateFileOptimistic passes to updateFileRawOptimistic. |
| none | `TomlParse` | The parse arrow function updateToml passes to updateFileOptimistic. |
| none | `TomlParse.run` | The parse arrow function updateToml passes to updateFileOptimistic. |
| none | `TomlSerialize` | The serialize arrow function updateToml passes to updateFileOptimistic. |
| none | `TomlSerialize.run` | The serialize arrow function updateToml passes to updateFileOptimistic. |
| none | `osTmpDir` | Replaces `os.tmpdir`. |
| none | `osHomedir` | Replaces Bun's `os.homedir`: HOME, else the passwd entry (USERPROFILE on Windows). |

#### `packages/node-utils/src/lib/photo-folders.ts` to `packages-zig/node-utils-zig/src/lib/photo-folders.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `parseXdgPicturesDir` | `parseXdgPicturesDir` |  |
| `readXdgPicturesDir` | `readXdgPicturesDir` |  |
| `getPhotoFolderCandidates` | `getPhotoFolderCandidates` |  |
| `filterExistingFolders` | `filterExistingFolders` |  |
| `getDefaultPhotoFolders` | `getDefaultPhotoFolders` |  |
| none | `matchXdgPicturesDir` | The regular expression `/^XDG_PICTURES_DIR\s*=\s*"(.*)"\s*$/` parseXdgPicturesDir runs inline. |
| none | `processPlatform` | Replaces `process.platform`. |

#### `packages/node-utils/src/lib/pipe.ts` to no Zig file

| TypeScript | Zig | Notes |
|---|---|---|
| `pipe` | none | No counterpart needed: a Zig IReadStream is destroyed by its reader, and EncryptedStorage's decrypted stream destroys the file stream beneath it (DecryptedReadStream.destroy), which is what the `close` handler of pipe does. |

#### `packages/node-utils/src/lib/termination.ts` to `packages-zig/node-utils-zig/src/lib/termination.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `invokeTerminationCallbacks` | `invokeTerminationCallbacks` |  |
| `exit` | `exit` |  |
| `registerTerminationCallback` | `registerTerminationCallback` |  |
| `initializeTerminationHandlers` | `initializeTerminationHandlers` |  |
| none | `TerminationCallback` | The TypeScript type of the same name, as a context and a function. |
| none | `exitProcess` | Replaces `process.exit` and the `'exit'` handler of initializeTerminationHandlers, which logs the exit code. |
| none | `clearTerminationCallbacks` | For the tests: empties the list of callbacks. |
| none | `handleSignal` | Replaces `process.on('SIGTERM' / 'SIGINT')`: the POSIX signal handler, which wakes the watcher thread. |
| none | `handleConsoleCtrl` | Replaces `process.on('SIGINT')` on Windows, where Ctrl+C arrives through the console control handler. |
| none | `shutdownOnSignal` | The `process.on('SIGTERM')` and `process.on('SIGINT')` handlers of initializeTerminationHandlers. |
| none | `shutdownOnUnhandledRejection` | The `process.on('unhandledRejection')` handler of initializeTerminationHandlers, which a signal handler that throws twice reaches. The uncaughtException handler has no counterpart: Zig errors are returned to main. |
| none | `waitForSignal` | Replaces the event loop delivering a signal: blocks the watcher thread until one arrives. |
| none | `watchSignals` | Replaces the event loop delivering a signal: the thread that runs the signal handlers. |

#### `packages/node-utils/src/lib/test-random-generator.ts` to no Zig file

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| `TestRandomGenerator` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `TestRandomGenerator.random` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `TestRandomGenerator.randomInt` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `TestRandomGenerator.randomString` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `TestRandomGenerator.reset` | none | Not reached by the CLI: tree-shaken out of the bundle. |

#### `packages/node-utils/src/lib/test-temp-dir.ts` to no Zig file

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| `getTestTempRoot` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `createTestTempDir` | none | Not reached by the CLI: tree-shaken out of the bundle. |

#### `packages/node-utils/src/lib/test-timestamp-provider.ts` to `packages-zig/node-utils-zig/src/lib/test-timestamp-provider.zig`

Used by init-cmd.ts and worker.ts when NODE_ENV is testing (the bundle metafile counts no bytes against the file itself).

| TypeScript | Zig | Notes |
|---|---|---|
| `TestTimestampProvider` | `TestTimestampProvider` |  |
| `TestTimestampProvider.now` | `TestTimestampProvider.now` |  |
| `TestTimestampProvider.dateNow` | `TestTimestampProvider.dateNow` |  |
| `TestTimestampProvider.reset` | `TestTimestampProvider.reset` |  |
| none | `TestTimestampProvider.timestampProvider` | The ITimestampProvider interface of the provider. |
| none | `TestTimestampProvider.nowErased` | The vtable entry of now. |
| none | `TestTimestampProvider.dateNowErased` | The vtable entry of dateNow. |

#### `packages/node-utils/src/lib/test-uuid-generator.ts` to `packages-zig/node-utils-zig/src/lib/test-uuid-generator.zig`

Used by init-cmd.ts and worker.ts when NODE_ENV is testing (the bundle metafile counts no bytes against the file itself).

| TypeScript | Zig | Notes |
|---|---|---|
| `TestUuidGenerator` | `TestUuidGenerator` |  |
| `TestUuidGenerator.constructor` | `TestUuidGenerator.init` |  |
| `TestUuidGenerator.generate` | `TestUuidGenerator.generate` |  |
| `TestUuidGenerator.acquireLock` | `TestUuidGenerator.acquireLock` |  |
| `TestUuidGenerator.releaseLock` | `TestUuidGenerator.releaseLock` |  |
| `TestUuidGenerator.reset` | `TestUuidGenerator.reset` |  |
| `TestUuidGenerator.generateDeterministicUuid` | `TestUuidGenerator.generateDeterministicUuid` | Shares the one in utils-zig, which takes the counter as a JavaScript number. |
| none | `TestUuidGenerator.uuidGenerator` | The IUuidGenerator interface of the generator. |
| none | `TestUuidGenerator.generateErased` | The vtable entry of generate. |

#### Zig files with no TypeScript file

| Zig file | What it is |
|---|---|
| `packages-zig/node-utils-zig/src/lib/path.zig` | Replaces `node:path` (posix and win32 join, normalize, dirname, basename, extname, isAbsolute). |
| `packages-zig/node-utils-zig/src/lib/process-env.zig` | Replaces `process.env`. |
| `packages-zig/node-utils-zig/src/lib/toml.zig` | Replaces the `smol-toml` npm package (parse and stringify). |
| `packages-zig/node-utils-zig/src/lib/yaml.zig` | Replaces the `js-yaml` npm package for the subset psi reads and writes (see "JavaScript behaviour not emulated"). |

<!-- end tables -->

## utils

`packages/utils` to `packages-zig/utils-zig`. Zig only: `console.zig`, `errors.zig`, `js-number.zig`, `js-string.zig` and `standard-streams.zig` (see the last table).

<!-- tables: packages/utils utils.txt -->

#### `packages/utils/src/index.ts` to `packages-zig/utils-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/utils/src/lib/batch-generator.ts` to `packages-zig/utils-zig/src/lib/batch-generator.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `batchGenerator` | `BatchGenerator` |  |
| none | `batchGenerator` | The async generator batchGenerator returns, as an iterator (the function above it is BatchGenerator's constructor). |

#### `packages/utils/src/lib/fatal-error.ts` to `packages-zig/utils-zig/src/lib/fatal-error.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `FatalError` | `FatalError` |  |
| `FatalError.constructor` | `FatalError.throw` | `throw new FatalError(message)`, which records the message and returns error.FatalError. |
| none | `FatalError.isInstance` | Replaces `error instanceof FatalError`. |

#### `packages/utils/src/lib/format.ts` to `packages-zig/utils-zig/src/lib/format.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `formatFileSize` | `formatFileSize` |  |

#### `packages/utils/src/lib/image.ts` to `packages-zig/utils-zig/src/lib/image.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `getImageTransformation` | `getImageTransformation` |  |
| `getVideoTransformation` | `getVideoTransformation` |  |
| none | `IImageTransformation` | The TypeScript interface of the same name, as a struct. |
| none | `IOrientation` | The TypeScript interface of the same name, as a struct. |
| none | `toOrientation` | Reads a JavaScript value as the orientation the switch compares with `===`, or as String(value). |
| none | `arrayToString` | Replaces `String(array)`. |
| none | `isTruthy` | Replaces JavaScript truthiness. |

#### `packages/utils/src/lib/log-exceptions.ts` to no Zig file

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| `logExceptions` | none | Not reached by the CLI: tree-shaken out of the bundle. |

#### `packages/utils/src/lib/log.ts` to `packages-zig/utils-zig/src/lib/log.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `setLog` | `setLog` |  |
| none | `ILogDetails` | The TypeScript interface of the same name, as a struct. |
| none | `IToolOutput` | The TypeScript interface of the same name, as a struct. |
| none | `ILog` | The TypeScript interface of the same name, as a struct. |
| none | `ILog.info` | The dispatch of the ILog interface method of the same name. |
| none | `ILog.verbose` | The dispatch of the ILog interface method of the same name. |
| none | `ILog.exception` | The dispatch of the ILog interface method of the same name. |
| none | `ILog.warn` | The dispatch of the ILog interface method of the same name. |
| none | `ILog.debug` | The dispatch of the ILog interface method of the same name. |
| none | `ILog.tool` | The dispatch of the ILog interface method of the same name. |
| none | `ILog.event` | The dispatch of the ILog interface method of the same name. |
| none | `ILog.verboseEnabled` | The dispatch of the ILog interface method of the same name. |
| none | `ILog.getLogDetails` | The dispatch of the ILog interface method of the same name. |
| none | `ConsoleLog` | The object literal assigned to `log`. |
| none | `ConsoleLog.ilog` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.info` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.verbose` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.logError` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.exception` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.warn` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.debug` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.tool` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.event` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.verboseEnabled` | The method of the same name of the object literal assigned to `log` (logError is `error`). |
| none | `ConsoleLog.getLogDetails` | The method of the same name of the object literal assigned to `log` (logError is `error`). |

#### `packages/utils/src/lib/mock-timestamp-provider.ts` to no Zig file

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| `MockTimestampProvider` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `MockTimestampProvider.constructor` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `MockTimestampProvider.now` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `MockTimestampProvider.dateNow` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `MockTimestampProvider.setTimestamp` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `MockTimestampProvider.advance` | none | Not reached by the CLI: tree-shaken out of the bundle. |

#### `packages/utils/src/lib/random-generator.ts` to no Zig file

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| `RandomGenerator` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `RandomGenerator.random` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `RandomGenerator.randomInt` | none | Not reached by the CLI: tree-shaken out of the bundle. |
| `RandomGenerator.randomString` | none | Not reached by the CLI: tree-shaken out of the bundle. |

#### `packages/utils/src/lib/random-uuid-generator.ts` to `packages-zig/utils-zig/src/lib/random-uuid-generator.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `RandomUuidGenerator` | `RandomUuidGenerator` |  |
| `RandomUuidGenerator.generate` | `RandomUuidGenerator.generate` |  |
| none | `RandomUuidGenerator.uuidGenerator` | The IUuidGenerator interface of the generator. |
| none | `RandomUuidGenerator.generateErased` | The vtable entry of generate. |

#### `packages/utils/src/lib/retry-or-log.ts` to `packages-zig/utils-zig/src/lib/retry-or-log.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `retryOrLog` | `retryOrLog` |  |

#### `packages/utils/src/lib/retry.ts` to `packages-zig/utils-zig/src/lib/retry.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `rejectAfter` | none | Not reached by the CLI. |
| `retryOnce` | `retryOnce` |  |
| `retry` | `retry` |  |
| none | `OperationResult` | The ReturnT of an operation, which Zig reads from the operation's run method. |
| none | `operationSourceOf` | Replaces `operation.toString().replace(/\s+/g, " ").slice(0, 200)`: the operation declares the text Bun gives for its arrow function. |
| none | `OperationTask` | Runs the operation concurrently with the timer (the promise of `operation()`). |
| none | `waitForTimeout` | The `setTimeout` of retryOnce. |
| none | `logVerboseError` | `log.verbose(\`Error: ${JSON.stringify(serializeError(error), null, 2)}\`)`, without the stack a Zig error does not have. |
| none | `logRetryWarning` | The `log.warn` of a failed attempt that is tried again. |

#### `packages/utils/src/lib/reverse-geocode.ts` to `packages-zig/utils-zig/src/lib/reverse-geocode.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `convertNumber` | `convertNumber` |  |
| `convertToDegrees` | `convertToDegrees` |  |
| `isLocationInRange` | `isLocationInRange` |  |
| `convertExifCoordinates` | `convertExifCoordinates` |  |
| `checkCoordinateOk` | `checkCoordinateOk` |  |
| `getFirstResultOfType` | `getFirstResultOfType` |  |
| `parseReverseGeocodeResult` | `parseReverseGeocodeResult` |  |
| `chooseBestResult` | `chooseBestResult` |  |
| `reverseGeocode` | `reverseGeocode` |  |
| none | `ILocation` | The TypeScript interface of the same name, as a struct. |
| none | `numberOf` | Replaces the conversion of a value to a number that division does. |
| none | `isString` | Replaces `value === text`. |
| none | `formatCoordinate` | Replaces `${coordinate}` in a template string. |
| none | `IReverseGeocodeResult` | The TypeScript interface of the same name, as a struct. |
| none | `typesInclude` | Replaces `result.types.includes(type)`. |
| none | `getJson` | Replaces `axios.get` with an Accept: application/json header. |
| none | `axiosResponseData` | Replaces axios's transformResponse: JSON.parse of the body, or the body itself when it is not JSON. |

#### `packages/utils/src/lib/sleep.ts` to `packages-zig/utils-zig/src/lib/sleep.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `sleep` | `sleep` |  |

#### `packages/utils/src/lib/swallow-error.ts` to `packages-zig/utils-zig/src/lib/swallow-error.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `swallowError` | `swallowError` |  |

#### `packages/utils/src/lib/test-uuid-generator.ts` to `packages-zig/utils-zig/src/lib/test-uuid-generator.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| `TestUuidGenerator` | `TestUuidGenerator` |  |
| `TestUuidGenerator.generate` | `TestUuidGenerator.generate` |  |
| `TestUuidGenerator.reset` | `TestUuidGenerator.reset` |  |
| `TestUuidGenerator.generateDeterministicUuid` | `TestUuidGenerator.generateDeterministicUuid` |  |
| none | `jsToUint32` | Replaces JavaScript's ToUint32 (`>>> 0`). |
| none | `jsToInt32` | Replaces JavaScript's ToInt32 (`^`, `&`, `\|`). |
| none | `jsXor` | Replaces `left ^ right` on numbers. |
| none | `jsUnsignedShiftRight` | Replaces `value >>> shift`. |
| none | `TestUuidGenerator.uuidGenerator` | The IUuidGenerator interface of the generator. |
| none | `TestUuidGenerator.generateErased` | The vtable entry of generate. |

#### `packages/utils/src/lib/timestamp-provider.ts` to `packages-zig/utils-zig/src/lib/timestamp-provider.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `TimestampProvider` | `TimestampProvider` |  |
| `TimestampProvider.now` | `TimestampProvider.now` |  |
| `TimestampProvider.dateNow` | `TimestampProvider.dateNow` |  |
| none | `Date` | Replaces JavaScript's Date, as milliseconds since the epoch. |
| none | `Date.toISOString` | Replaces `Date.prototype.toISOString`. |
| none | `CivilDate` | The calendar date toISOString writes. |
| none | `civilFromDays` | Converts days since the epoch to a calendar date, as Date does. |
| none | `ITimestampProvider` | The TypeScript interface of the same name, as a struct. |
| none | `ITimestampProvider.now` | The dispatch of the ITimestampProvider interface method of the same name. |
| none | `ITimestampProvider.dateNow` | The dispatch of the ITimestampProvider interface method of the same name. |
| none | `TimestampProvider.timestampProvider` | The ITimestampProvider interface of the provider. |
| none | `TimestampProvider.nowErased` | The vtable entry of now. |
| none | `TimestampProvider.dateNowErased` | The vtable entry of dateNow. |

#### `packages/utils/src/lib/try-or-log.ts` to no Zig file

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| `tryOrLog` | none | Not reached by the CLI: tree-shaken out of the bundle. |

#### `packages/utils/src/lib/uuid-generator.ts` to `packages-zig/utils-zig/src/lib/uuid-generator.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IUuidGenerator` | The TypeScript interface of the same name, as a struct. |
| none | `IUuidGenerator.generate` | The dispatch of the IUuidGenerator interface method. |

#### `packages/utils/src/lib/wrapped-error.ts` to `packages-zig/utils-zig/src/lib/wrapped-error.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `formatErrorChain` | `formatErrorChain` |  |
| `WrappedError` | `WrappedError` |  |
| `WrappedError.constructor` | `WrappedError.throw` | `throw new WrappedError(message, { cause })`, where the cause is the error last thrown on the thread. |
| none | `writeErrorChain` | The body of formatErrorChain, writing to a writer so the default log need not allocate. |
| none | `stackName` | The name the first line of an error's stack shows. |
| none | `WrappedError.isInstance` | Replaces `error instanceof WrappedError`. |

#### Zig files with no TypeScript file

| Zig file | What it is |
|---|---|
| `packages-zig/utils-zig/src/lib/console.zig` | Replaces `console.log`, `console.error`, `console.warn` and `console.debug`. |
| `packages-zig/utils-zig/src/lib/errors.zig` | Replaces the message, name and cause a JavaScript error carries, which a Zig error cannot: the error last thrown on the thread is recorded here. |
| `packages-zig/utils-zig/src/lib/js-number.zig` | Replaces JavaScript's `parseInt`, `parseFloat` and `String(number)`. |
| `packages-zig/utils-zig/src/lib/js-string.zig` | Replaces `String.prototype.trim`, `trimStart` and `trimEnd`. |
| `packages-zig/utils-zig/src/lib/standard-streams.zig` | Replaces `process.stdout` and `process.stderr`. |

<!-- end tables -->

## encryption

`packages/encryption` to `packages-zig/encryption-zig`. Zig only: `node-crypto.zig`, the node:crypto functions on OpenSSL's libcrypto.

<!-- tables: packages/encryption encryption.txt -->

#### `packages/encryption/src/index.ts` to `packages-zig/encryption-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/encryption/src/lib/encrypt-buffer.ts` to `packages-zig/encryption-zig/src/lib/encrypt-buffer.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `encryptBuffer` | `encryptBuffer` |  |
| `requireWrappableKey` | `requireWrappableKey` |  |
| `decryptBuffer` | `decryptBuffer` |  |
| `decryptNewFormat` | `decryptNewFormat` |  |
| `decryptLegacy` | `decryptLegacy` |  |
| none | `normalizeEncryptionType` | Replaces `.toString("ascii").replace(/\0/g, "").trim()` of the type field. |
| none | `includesString` | Replaces `Array.prototype.includes` for strings. |
| none | `clampedSlice` | Replaces `Buffer.slice`, which clamps its bounds. |

#### `packages/encryption/src/lib/encrypt-stream.ts` to `packages-zig/encryption-zig/src/lib/encrypt-stream.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `computeEncryptedLength` | `computeEncryptedLength` |  |
| `createEncryptionStream` | `createEncryptionStream` |  |
| `createDecryptionStream` | `createDecryptionStream` |  |
| none | `TransformStream` | Replaces `new Transform({ transform, flush })` of node:stream, pulled by its reader. |
| none | `TransformStream.init` | Replaces `new Transform({ transform, flush })` of node:stream (push is `this.push`). |
| none | `TransformStream.push` | Replaces `new Transform({ transform, flush })` of node:stream (push is `this.push`). |
| none | `TransformStream.pull` | Replaces `new Transform({ transform, flush })` of node:stream (push is `this.push`). |
| none | `TransformStream.streamFunction` | Replaces `new Transform({ transform, flush })` of node:stream (push is `this.push`). |
| none | `EncryptionStream` | The state createEncryptionStream's closures share. |
| none | `EncryptionStream.reader` | Zig plumbing: the `std.Io.Reader` side of a Node stream. |
| none | `EncryptionStream.sendHeader` | The nested function sendHeader. |
| none | `EncryptionStream.transformChunk` | The `transform` option of the Transform. |
| none | `EncryptionStream.flush` | The `flush` option of the Transform. |
| none | `DecryptionStream` | The state createDecryptionStream's closures share. |
| none | `DecryptionStream.reader` | Zig plumbing: the `std.Io.Reader` side of a Node stream. |
| none | `DecryptionStream.transformChunk` | The `transform` option of the Transform. |
| none | `DecryptionStream.flush` | The `flush` option of the Transform. |

#### `packages/encryption/src/lib/encryption-constants.ts` to `packages-zig/encryption-zig/src/lib/encryption-constants.zig`


#### `packages/encryption/src/lib/encryption-types.ts` to `packages-zig/encryption-zig/src/lib/encryption-types.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IStorageOptions` | The TypeScript interface of the same name, as a struct. |

#### `packages/encryption/src/lib/key-utils.ts` to `packages-zig/encryption-zig/src/lib/key-utils.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `generateKeyPair` | `generateKeyPair` |  |
| `saveKeyPair` | none | Not reached by the CLI. |
| `loadPrivateKey` | none | Not reached by the CLI. |
| `loadPublicKey` | none | Not reached by the CLI. |
| `loadOrGenerateKeyPair` | none | Not reached by the CLI. |
| `exportPublicKeyToPem` | `exportPublicKeyToPem` |  |
| `hashPublicKey` | `hashPublicKey` |  |
| `loadEncryptionKeysFromPem` | `loadEncryptionKeysFromPem` |  |
| `loadEncryptionKeys` | none | Not reached by the CLI, which loads keys from the vault as PEM. |
| none | `IKeyPair` | The TypeScript interface of the same name, as a struct. |
| none | `IEncryptionKeyPem` | The TypeScript interface of the same name, as a struct. |
| none | `ILoadedEncryptionKeys` | The TypeScript interface of the same name, as a struct. |

#### Zig files with no TypeScript file

| Zig file | What it is |
|---|---|
| `packages-zig/encryption-zig/src/lib/node-crypto.zig` | Replaces the node:crypto functions the encryption uses (RSA-OAEP, AES-256-CBC, key import and export, random bytes, signing), on OpenSSL's libcrypto. |

<!-- end tables -->

## vault

`packages/vault` to `packages-zig/vault-zig`.

<!-- tables: packages/vault vault.txt -->

#### `packages/vault/src/index.ts` to `packages-zig/vault-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/vault/src/lib/get-vault.ts` to `packages-zig/vault-zig/src/lib/get-vault.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `getDefaultVaultType` | `getDefaultVaultType` |  |
| `getVault` | `getVault` |  |
| `instantiateVault` | `instantiateVault` |  |
| none | `lockVaultInstances` | Guards the instance cache, which Zig worker threads share (TypeScript runs on one thread). |
| none | `unlockVaultInstances` | Guards the instance cache, which Zig worker threads share (TypeScript runs on one thread). |
| none | `processPlatform` | Replaces `process.platform`. |

#### `packages/vault/src/lib/keychain-types.ts` to `packages-zig/vault-zig/src/lib/keychain-types.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `toKeychainName` | `toKeychainName` |  |
| `fromKeychainName` | `fromKeychainName` |  |
| `runCommand` | `runCommand` |  |
| none | `IKeychainPayload` | The TypeScript interface of the same name, as a struct. |
| none | `ISpawnResult` | The TypeScript interface of the same name, as a struct. |
| none | `setSpawnFunction` | For the tests: replaces child_process.spawn (the TypeScript tests use jest.spyOn). Test-only scaffolding in the app code. |
| none | `spawn` | Replaces `child_process.spawn` with piped stdio, collecting what the "data" and "close" events give. |
| none | `spawnChildProcess` | Replaces `child_process.spawn` with piped stdio, collecting what the "data" and "close" events give. |

#### `packages/vault/src/lib/linux-keychain-vault.ts` to `packages-zig/vault-zig/src/lib/linux-keychain-vault.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `checkPrereqsOnce` | `checkPrereqsOnce` |  |
| `checkTool` | `checkTool` |  |
| `parseSearchOutput` | `parseSearchOutput` |  |
| `runSecretToolSearchAll` | `runSecretToolSearchAll` |  |
| `runSecretToolSearchOne` | `runSecretToolSearchOne` |  |
| `runSecretToolStore` | `runSecretToolStore` |  |
| `LinuxKeychainVault` | `LinuxKeychainVault` |  |
| `LinuxKeychainVault.get` | `LinuxKeychainVault.get` |  |
| `LinuxKeychainVault.set` | `LinuxKeychainVault.set` |  |
| `LinuxKeychainVault.list` | `LinuxKeychainVault.list` |  |
| `LinuxKeychainVault.delete` | `LinuxKeychainVault.delete` |  |
| `LinuxKeychainVault.checkPrereqs` | `LinuxKeychainVault.checkPrereqs` |  |
| none | `resetToolChecked` | For the tests: forgets the tool check (a TypeScript test file gets a fresh module). Test-only scaffolding in the app code. |
| none | `ISearchEntry` | The TypeScript interface of the same name, as a struct. |
| none | `SearchParseState` | The variables flushEntry closes over in parseSearchOutput. |
| none | `SearchParseState.flushEntry` | The nested function flushEntry. |
| none | `LinuxKeychainVault.init` | The constructor. |
| none | `LinuxKeychainVault.vault` | The IVault interface of the vault. |
| none | `LinuxKeychainVault.deleteErased` | The vtable entry of delete. |
| none | `LinuxKeychainVault.checkPrereqsErased` | The vtable entry of checkPrereqs. |
| none | `LinuxKeychainVault.getErased` | The vtable entry of get. |
| none | `LinuxKeychainVault.setErased` | The vtable entry of set. |
| none | `LinuxKeychainVault.listErased` | The vtable entry of list. |

#### `packages/vault/src/lib/macos-keychain-vault.ts` to `packages-zig/vault-zig/src/lib/macos-keychain-vault.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `parseKeychainDump` | `parseKeychainDump` |  |
| `MacOSKeychainVault` | `MacOSKeychainVault` |  |
| `MacOSKeychainVault.checkPrereqs` | `MacOSKeychainVault.checkPrereqs` |  |
| `MacOSKeychainVault.checkTool` | `MacOSKeychainVault.checkTool` |  |
| `MacOSKeychainVault.get` | `MacOSKeychainVault.get` |  |
| `MacOSKeychainVault.set` | `MacOSKeychainVault.set` |  |
| `MacOSKeychainVault.list` | `MacOSKeychainVault.list` |  |
| `MacOSKeychainVault.delete` | `MacOSKeychainVault.delete` |  |
| none | `matchBlobAttribute` | Replaces the regular expression `/"<tag>"<blob>="([^"]+)"/`. |
| none | `MacOSKeychainVault.init` | The constructor. |
| none | `MacOSKeychainVault.vault` | The IVault interface of the vault. |
| none | `MacOSKeychainVault.deleteErased` | The vtable entry of delete. |
| none | `MacOSKeychainVault.checkPrereqsErased` | The vtable entry of checkPrereqs. |
| none | `MacOSKeychainVault.getErased` | The vtable entry of get. |
| none | `MacOSKeychainVault.setErased` | The vtable entry of set. |
| none | `MacOSKeychainVault.listErased` | The vtable entry of list. |

#### `packages/vault/src/lib/plaintext-vault.ts` to `packages-zig/vault-zig/src/lib/plaintext-vault.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `ensureDir` | `ensureDir` |  |
| `getVaultFilePath` | `getVaultFilePath` |  |
| `applyFileMode` | `applyFileMode` |  |
| `readVaultFile` | `readVaultFile` |  |
| `updateVaultFile` | `updateVaultFile` |  |
| `PlaintextVault` | `PlaintextVault` |  |
| `PlaintextVault.constructor` | `PlaintextVault.init` |  |
| `PlaintextVault.get` | `PlaintextVault.get` |  |
| `PlaintextVault.set` | `PlaintextVault.set` |  |
| `PlaintextVault.list` | `PlaintextVault.list` |  |
| `PlaintextVault.delete` | `PlaintextVault.delete` |  |
| `PlaintextVault.exists` | none | Not reached by the CLI. |
| `PlaintextVault.checkPrereqs` | `PlaintextVault.checkPrereqs` |  |
| none | `DEFAULT_VAULT_DIR` | The constant DEFAULT_VAULT_DIR, computed on demand because the environment is set by main. |
| none | `modeToPermissions` | Replaces the numeric mode node:fs takes. |
| none | `isArrayIndex` | Replaces the ordering of a JavaScript object's keys (array index names first). |
| none | `orderLikeJavaScript` | Replaces the ordering of a JavaScript object's keys (array index names first). |
| none | `parseVaultFile` | `JSON.parse(raw) as IVaultFile`. |
| none | `VaultFileParse` | The parse arrow function updateVaultFile passes to updateFileOptimistic. |
| none | `VaultFileParse.run` | The parse arrow function updateVaultFile passes to updateFileOptimistic. |
| none | `VaultFileSerialize` | The serialize arrow function updateVaultFile passes to updateFileOptimistic. |
| none | `VaultFileSerialize.run` | The serialize arrow function updateVaultFile passes to updateFileOptimistic. |
| none | `VaultFileMutator` | The mutator arrow function updateVaultFile passes to updateFileOptimistic. |
| none | `toSecret` | Reads a secret out of the parsed vault file as an ISecret. |
| none | `fromSecret` | The object a secret is stored as. |
| none | `SetSecretMutator` | The arrow function PlaintextVault.set passes to updateVaultFile. |
| none | `SetSecretMutator.run` | The arrow function PlaintextVault.set passes to updateVaultFile. |
| none | `DeleteSecretMutator` | The arrow function PlaintextVault.delete passes to updateVaultFile. |
| none | `DeleteSecretMutator.run` | The arrow function PlaintextVault.delete passes to updateVaultFile. |
| none | `PlaintextVault.vault` | The IVault interface of the vault. |
| none | `PlaintextVault.deleteErased` | The vtable entry of delete. |
| none | `PlaintextVault.checkPrereqsErased` | The vtable entry of checkPrereqs. |
| none | `PlaintextVault.getErased` | The vtable entry of get. |
| none | `PlaintextVault.setErased` | The vtable entry of set. |
| none | `PlaintextVault.listErased` | The vtable entry of list. |

#### `packages/vault/src/lib/vault.ts` to `packages-zig/vault-zig/src/lib/vault.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `ISecret` | The TypeScript interface of the same name, as a struct. |
| none | `IVault` | The TypeScript interface of the same name, as a struct. |
| none | `IVault.get` | The dispatch of the IVault interface method of the same name. |
| none | `IVault.set` | The dispatch of the IVault interface method of the same name. |
| none | `IVault.list` | The dispatch of the IVault interface method of the same name. |
| none | `IVault.delete` | The dispatch of the IVault interface method of the same name. |
| none | `IVault.checkPrereqs` | The dispatch of the IVault interface method of the same name. |
| none | `IPrereqCheckResult` | The TypeScript interface of the same name, as a struct. |

#### `packages/vault/src/lib/windows-keychain-vault.ts` to `packages-zig/vault-zig/src/lib/windows-keychain-vault.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `checkPrereqsOnce` | `checkPrereqsOnce` |  |
| `checkTool` | `checkTool` |  |
| `runPowerShell` | `runPowerShell` |  |
| `WindowsKeychainVault` | `WindowsKeychainVault` |  |
| `WindowsKeychainVault.get` | `WindowsKeychainVault.get` |  |
| none | `resetToolChecked` | For the tests: forgets the tool check (a TypeScript test file gets a fresh module). Test-only scaffolding in the app code. |
| none | `escapeSingleQuotes` | Replaces `.replace(/'/g, "''")`. |
| none | `WindowsKeychainVault.init` | The constructor. |
| none | `WindowsKeychainVault.vault` | The IVault interface of the vault. |
| none | `WindowsKeychainVault.set` | The TypeScript method of the same name (the table's reader of the TypeScript loses the class after the first multi-line PowerShell script). |
| none | `WindowsKeychainVault.list` | The TypeScript method of the same name (see set). |
| none | `WindowsKeychainVault.delete` | The TypeScript method of the same name (see set). |
| none | `WindowsKeychainVault.checkPrereqs` | The TypeScript method of the same name (see set). |
| none | `WindowsKeychainVault.deleteErased` | The vtable entry of delete. |
| none | `WindowsKeychainVault.checkPrereqsErased` | The vtable entry of checkPrereqs. |
| none | `WindowsKeychainVault.getErased` | The vtable entry of get. |
| none | `WindowsKeychainVault.setErased` | The vtable entry of set. |
| none | `WindowsKeychainVault.listErased` | The vtable entry of list. |

<!-- end tables -->

## fuzzy-match

`packages/fuzzy-match` to `packages-zig/fuzzy-match-zig`.

<!-- tables: packages/fuzzy-match fuzzy-match.txt -->

#### `packages/fuzzy-match/src/index.ts` to `packages-zig/fuzzy-match-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/fuzzy-match/src/lib/fuzzy-match.ts` to `packages-zig/fuzzy-match-zig/src/lib/fuzzy-match.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `levenshteinDistance` | `levenshteinDistance` |  |
| `fuzzyMatch` | `fuzzyMatch` |  |
| none | `toCodeUnits` | Converts UTF-8 to the UTF-16 code units a JavaScript string is made of. |

<!-- end tables -->

## config

`packages/config` has no Zig package: its two constants live in the CLI's `config.zig`.

<!-- tables: packages/config config.txt -->

#### `packages/config/src/index.ts` to `apps/cli-zig/src/lib/config.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IBuildMetadata` | The type of the buildMetadata object literal, named. |

<!-- end tables -->

## lan-share-network

`packages/lan-share-network` to `packages-zig/lan-share-network-zig`. Zig only: `https.zig` (node:https and node:tls over libssl) and `socket.zig` (node:dgram and node:net).

<!-- tables: packages/lan-share-network lan-share-network.txt -->

#### `packages/lan-share-network/src/index.ts` to `packages-zig/lan-share-network-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/lan-share-network/src/lib/lan-share-receiver.ts` to `packages-zig/lan-share-network-zig/src/lib/lan-share-receiver.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `generateSelfSignedCert` | `generateSelfSignedCert` |  |
| `extractDerFromPem` | `extractDerFromPem` |  |
| `buildSelfSignedCert` | `buildSelfSignedCert` |  |
| `encodeAsn1Length` | `encodeAsn1Length` |  |
| `encodeAsn1Tag` | `encodeAsn1Tag` |  |
| `encodeAsn1Sequence` | `encodeAsn1Sequence` |  |
| `encodeAsn1Set` | `encodeAsn1Set` |  |
| `encodeAsn1Integer` | `encodeAsn1Integer` |  |
| `encodeAsn1BitString` | `encodeAsn1BitString` |  |
| `encodeAsn1Null` | `encodeAsn1Null` |  |
| `encodeAsn1Oid` | `encodeAsn1Oid` |  |
| `encodeAsn1Utf8String` | `encodeAsn1Utf8String` |  |
| `encodeAsn1UtcTime` | `encodeAsn1UtcTime` |  |
| `encodeAsn1Explicit` | `encodeAsn1Explicit` |  |
| `LanShareReceiver` | `LanShareReceiver` |  |
| `LanShareReceiver.constructor` | `LanShareReceiver.init` |  |
| `LanShareReceiver.start` | `LanShareReceiver.start` |  |
| `LanShareReceiver.receive` | `LanShareReceiver.receive` |  |
| `LanShareReceiver.cancel` | `LanShareReceiver.cancel` |  |
| `LanShareReceiver.handleRequest` | `LanShareReceiver.handleRequest` |  |
| `LanShareReceiver.complete` | `LanShareReceiver.complete` |  |
| none | `ISelfSignedCert` | The TypeScript interface of the same name, as a struct. |
| none | `LanShareReceiver.deinit` | Zig plumbing: frees what the struct owns (garbage collected in TypeScript). |
| none | `LanShareReceiver.allocator` | The receiver's arena, which its threads share (the JavaScript heap). |
| none | `LanShareReceiver.broadcast` | The body of the broadcast interval's callback: the announcement sent to the broadcast address and loopback. |
| none | `LanShareReceiver.broadcastEvery` | Replaces `setInterval` of the broadcast: a thread that sends the announcement until the receive is done. |
| none | `LanShareReceiver.serve` | Replaces `https.createServer(...).listen()`: a thread accepting connections. |
| none | `LanShareReceiver.waitForRequest` | Replaces node:http's keep-alive wait for the next request on a connection. |
| none | `LanShareReceiver.serveConnection` | Replaces node:https's handling of one connection (the TLS handshake, then its requests). |
| none | `LanShareReceiver.respondJson` | `response.writeHead(status, { "Content-Type": "application/json" }); response.end(body)`. |
| none | `LanShareReceiver.isFalsy` | Replaces JavaScript falsiness, for the callers' `if (!rawPayload)`. |
| none | `LanShareReceiver.shutdown` | The cleanup of complete(): the threads are joined and the sockets closed. |

#### `packages/lan-share-network/src/lib/lan-share-sender.ts` to `packages-zig/lan-share-network-zig/src/lib/lan-share-sender.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `generatePairingCode` | `generatePairingCode` |  |
| `LanShareSender` | `LanShareSender` |  |
| `LanShareSender.constructor` | `LanShareSender.init` |  |
| `LanShareSender.waitForReceiver` | `LanShareSender.waitForReceiver` |  |
| `LanShareSender.makeRequest` | `LanShareSender.makeRequest` |  |
| `LanShareSender.send` | `LanShareSender.send` |  |
| `LanShareSender.cancel` | `LanShareSender.cancel` |  |
| `LanShareSender.cleanupUdp` | `LanShareSender.cleanupUdp` |  |
| none | `sha256Hex` | `createHash("sha256").update(text).digest("hex")`. |
| none | `pairingCodeHashMatches` | `(JSON.parse(hashResponse.body) as IPairingCodeHashResponse).codeHash === codeHash` in send. |
| none | `parseIntLikeJavaScript` | `parseInt(parts[0], 10)` of the announced port in waitForReceiver. |

#### `packages/lan-share-network/src/lib/lan-share-types.ts` to `packages-zig/lan-share-network-zig/src/lib/lan-share-types.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.

| TypeScript | Zig | Notes |
|---|---|---|
| none | `IPairingCodeHashResponse` | The TypeScript interface of the same name, as a struct. |
| none | `IReceiverEndpoint` | The TypeScript interface of the same name, as a struct. |

#### Zig files with no TypeScript file

| Zig file | What it is |
|---|---|
| `packages-zig/lan-share-network-zig/src/lib/https.zig` | Replaces node:https and node:tls (over libssl). |
| `packages-zig/lan-share-network-zig/src/lib/socket.zig` | Replaces node:dgram and node:net (the operating system's socket API). |

<!-- end tables -->

## serialization

`packages/serialization` to `packages-zig/serialization-zig`. Zig only: `bson.zig` (the npm `bson` package), `js-date.zig`, `js-number.zig` and `json-parse.zig`.

<!-- tables: packages/serialization serialization.txt -->

#### `packages/serialization/src/index.ts` to `packages-zig/serialization-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/serialization/src/lib/serialization.ts` to `packages-zig/serialization-zig/src/lib/serialization.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `BinarySerializer` | `BinarySerializer` |  |
| `BinarySerializer.constructor` | `BinarySerializer.init` |  |
| `BinarySerializer.ensureCapacity` | `BinarySerializer.ensureCapacity` |  |
| `BinarySerializer.writeUInt32` | `BinarySerializer.writeUInt32` |  |
| `BinarySerializer.writeInt32` | `BinarySerializer.writeInt32` |  |
| `BinarySerializer.writeUInt64` | `BinarySerializer.writeUInt64` |  |
| `BinarySerializer.writeInt64` | `BinarySerializer.writeInt64` |  |
| `BinarySerializer.writeFloat` | `BinarySerializer.writeFloat` |  |
| `BinarySerializer.writeDouble` | `BinarySerializer.writeDouble` |  |
| `BinarySerializer.writeBoolean` | `BinarySerializer.writeBoolean` |  |
| `BinarySerializer.writeUInt8` | `BinarySerializer.writeUInt8` |  |
| `BinarySerializer.writeString` | `BinarySerializer.writeString` |  |
| `BinarySerializer.writeBuffer` | `BinarySerializer.writeBuffer` |  |
| `BinarySerializer.writeBytes` | `BinarySerializer.writeBytes` |  |
| `BinarySerializer.writeBSON` | `BinarySerializer.writeBSON` |  |
| `BinarySerializer.getBuffer` | `BinarySerializer.getBuffer` |  |
| `CompressedBinarySerializer` | `CompressedBinarySerializer` |  |
| `CompressedBinarySerializer.constructor` | `CompressedBinarySerializer.init` |  |
| `CompressedBinarySerializer.writeUInt32` | `CompressedBinarySerializer.writeUInt32` |  |
| `CompressedBinarySerializer.writeInt32` | `CompressedBinarySerializer.writeInt32` |  |
| `CompressedBinarySerializer.writeUInt64` | `CompressedBinarySerializer.writeUInt64` |  |
| `CompressedBinarySerializer.writeInt64` | `CompressedBinarySerializer.writeInt64` |  |
| `CompressedBinarySerializer.writeFloat` | `CompressedBinarySerializer.writeFloat` |  |
| `CompressedBinarySerializer.writeDouble` | `CompressedBinarySerializer.writeDouble` |  |
| `CompressedBinarySerializer.writeBoolean` | `CompressedBinarySerializer.writeBoolean` |  |
| `CompressedBinarySerializer.writeUInt8` | `CompressedBinarySerializer.writeUInt8` |  |
| `CompressedBinarySerializer.writeString` | `CompressedBinarySerializer.writeString` |  |
| `CompressedBinarySerializer.writeBuffer` | `CompressedBinarySerializer.writeBuffer` |  |
| `CompressedBinarySerializer.writeBytes` | `CompressedBinarySerializer.writeBytes` |  |
| `CompressedBinarySerializer.writeBSON` | `CompressedBinarySerializer.writeBSON` |  |
| `CompressedBinarySerializer.finish` | `CompressedBinarySerializer.finish` |  |
| `CompressedBinaryDeserializer` | `CompressedBinaryDeserializer` |  |
| `CompressedBinaryDeserializer.constructor` | `CompressedBinaryDeserializer.init` |  |
| `CompressedBinaryDeserializer.readUInt32` | `CompressedBinaryDeserializer.readUInt32` |  |
| `CompressedBinaryDeserializer.readInt32` | `CompressedBinaryDeserializer.readInt32` |  |
| `CompressedBinaryDeserializer.readUInt64` | `CompressedBinaryDeserializer.readUInt64` |  |
| `CompressedBinaryDeserializer.readInt64` | `CompressedBinaryDeserializer.readInt64` |  |
| `CompressedBinaryDeserializer.readFloat` | `CompressedBinaryDeserializer.readFloat` |  |
| `CompressedBinaryDeserializer.readDouble` | `CompressedBinaryDeserializer.readDouble` |  |
| `CompressedBinaryDeserializer.readBoolean` | `CompressedBinaryDeserializer.readBoolean` |  |
| `CompressedBinaryDeserializer.readUInt8` | `CompressedBinaryDeserializer.readUInt8` |  |
| `CompressedBinaryDeserializer.readString` | `CompressedBinaryDeserializer.readString` |  |
| `CompressedBinaryDeserializer.readBuffer` | `CompressedBinaryDeserializer.readBuffer` |  |
| `CompressedBinaryDeserializer.readBytes` | `CompressedBinaryDeserializer.readBytes` |  |
| `CompressedBinaryDeserializer.readBSON` | `CompressedBinaryDeserializer.readBSON` |  |
| `BinaryDeserializer` | `BinaryDeserializer` |  |
| `BinaryDeserializer.constructor` | `BinaryDeserializer.init` |  |
| `BinaryDeserializer.readUInt32` | `BinaryDeserializer.readUInt32` |  |
| `BinaryDeserializer.readInt32` | `BinaryDeserializer.readInt32` |  |
| `BinaryDeserializer.readUInt64` | `BinaryDeserializer.readUInt64` |  |
| `BinaryDeserializer.readInt64` | `BinaryDeserializer.readInt64` |  |
| `BinaryDeserializer.readFloat` | `BinaryDeserializer.readFloat` |  |
| `BinaryDeserializer.readDouble` | `BinaryDeserializer.readDouble` |  |
| `BinaryDeserializer.readBoolean` | `BinaryDeserializer.readBoolean` |  |
| `BinaryDeserializer.readUInt8` | `BinaryDeserializer.readUInt8` |  |
| `BinaryDeserializer.readString` | `BinaryDeserializer.readString` |  |
| `BinaryDeserializer.readBuffer` | `BinaryDeserializer.readBuffer` |  |
| `BinaryDeserializer.readBytes` | `BinaryDeserializer.readBytes` |  |
| `BinaryDeserializer.readBSON` | `BinaryDeserializer.readBSON` |  |
| `BinaryDeserializer.checkBounds` | `BinaryDeserializer.checkBounds` |  |
| `UnsupportedVersionError` | `UnsupportedVersionError` |  |
| `UnsupportedVersionError.constructor` | `UnsupportedVersionError.throw` | `throw new UnsupportedVersionError(...)`. |
| `typeCodeToBuffer` | `typeCodeToBuffer` |  |
| `save` | `save` |  |
| `load` | `load` |  |
| `loadVersion` | `loadVersion` |  |
| `verify` | `verify` |  |
| `applyMigrations` | none | Not reached by the CLI: no caller of load passes migrations. |
| `findMigrationPath` | none | Not reached by the CLI: no caller of load passes migrations. |
| none | `ISerializer` | The TypeScript interface of the same name, as a struct. |
| none | `ISerializer.writeUInt32` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeInt32` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeUInt64` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeInt64` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeFloat` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeDouble` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeBoolean` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeUInt8` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeString` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeBuffer` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeBytes` | The dispatch of the ISerializer interface method of the same name. |
| none | `ISerializer.writeBSON` | The dispatch of the ISerializer interface method of the same name. |
| none | `IDeserializer` | The TypeScript interface of the same name, as a struct. |
| none | `IDeserializer.readUInt32` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readInt32` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readUInt64` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readInt64` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readFloat` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readDouble` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readBoolean` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readUInt8` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readString` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readBuffer` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readBytes` | The dispatch of the IDeserializer interface method of the same name. |
| none | `IDeserializer.readBSON` | The dispatch of the IDeserializer interface method of the same name. |
| none | `SerializerFunction` | The TypeScript type of the same name, as a function type. |
| none | `DeserializerFunction` | The TypeScript type of the same name, as a function type. |
| none | `DeserializerEntry` | An entry of the `Record<number, DeserializerFunction>` load takes. |
| none | `checkUInt32` | The range check `writeUInt32LE` makes on a JavaScript number. |
| none | `BinarySerializer.asSerializer` | The ISerializer interface of the serializer. |
| none | `implementation` | Casts an interface's pointer back to its implementation. |
| none | `serializerVTable` | The ISerializer vtable of an implementation. |
| none | `CompressedBinarySerializer.asSerializer` | The ISerializer interface of the serializer. |
| none | `throwZlibError` | Replaces the errors node:zlib throws. |
| none | `gzipSync` | Replaces node:zlib's gzipSync (over zlib-ng). |
| none | `gunzipSync` | Replaces node:zlib's gunzipSync (over zlib-ng). |
| none | `CompressedBinaryDeserializer.asDeserializer` | The IDeserializer interface of the deserializer. |
| none | `BinaryDeserializer.asDeserializer` | The IDeserializer interface of the deserializer. |
| none | `deserializerVTable` | The IDeserializer vtable of an implementation. |
| none | `VersionList` | Replaces `availableVersions.join(', ')`. |
| none | `VersionList.format` | Replaces `availableVersions.join(', ')`. |
| none | `sha256` | `createHash('sha256').update(data).digest()`. |
| none | `WriteOperation` | Zig plumbing: the arrow function TypeScript passes to `retry`, as a struct with `run`. |
| none | `ReadOperation` | The `() => storage.read(filePath)` arrow function load and verify pass to retry. |
| none | `findDeserializer` | `deserializers[version]`. |
| none | `asciiString` | Replaces `buffer.toString('ascii')`, which drops the high bit of each byte. |
| none | `IVerifyResult` | The TypeScript interface of the same name, as a struct. |

#### Zig files with no TypeScript file

| Zig file | What it is |
|---|---|
| `packages-zig/serialization-zig/src/lib/bson.zig` | Replaces the npm `bson` package (serialize and deserialize with default options). |
| `packages-zig/serialization-zig/src/lib/js-date.zig` | Replaces JavaScript's Date parsing and formatting. |
| `packages-zig/serialization-zig/src/lib/js-number.zig` | Re-exports utils-zig's `String(number)`. |
| `packages-zig/serialization-zig/src/lib/json-parse.zig` | Replaces `JSON.parse`, producing a JavaScript value. |

<!-- end tables -->

## merkle-tree

`packages/merkle-tree` to `packages-zig/merkle-tree-zig`.

<!-- tables: packages/merkle-tree merkle-tree.txt -->

#### `packages/merkle-tree/src/index.ts` to `packages-zig/merkle-tree-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/merkle-tree/src/lib/buffer-map.ts` to `packages-zig/merkle-tree-zig/src/lib/buffer-map.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `BufferMap` | `BufferMap` |  |
| `BufferMap.constructor` | `BufferMap.init` | The constructor. |
| `BufferMap._hash` | `BufferMap._hash` | A method of the struct the generic BufferMap(V) returns. |
| `BufferMap.set` | `BufferMap.set` | A method of the struct the generic BufferMap(V) returns. |
| `BufferMap.get` | `BufferMap.get` | A method of the struct the generic BufferMap(V) returns. |
| `BufferMap.has` | none | Not reached by the CLI. |
| `BufferMap.delete` | none | Not reached by the CLI. |
| `BufferMap.clear` | none | Not reached by the CLI. |
| `BufferMap.size` | none | Not reached by the CLI. |
| `BufferMap.forEach` | none | Not reached by the CLI. |
| `BufferMap.values` | none | Not reached by the CLI. |
| `BufferMap.keys` | none | Not reached by the CLI. |
| `BufferMap.entries` | none | Not reached by the CLI. |

#### `packages/merkle-tree/src/lib/buffer-set.ts` to `packages-zig/merkle-tree-zig/src/lib/buffer-set.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `BufferSet` | `BufferSet` |  |
| `BufferSet.constructor` | `BufferSet.init` |  |
| `BufferSet._hash` | `BufferSet._hash` |  |
| `BufferSet.add` | `BufferSet.add` |  |
| `BufferSet.has` | `BufferSet.has` |  |
| `BufferSet.delete` | `BufferSet.delete` |  |
| `BufferSet.clear` | none | Not reached by the CLI. |
| `BufferSet.size` | none | Not reached by the CLI. |
| `BufferSet.forEach` | none | Not reached by the CLI. |
| `BufferSet.values` | `BufferSet.values` |  |
| `BufferSet.keys` | none | Not reached by the CLI. |
| `BufferSet.entries` | none | Not reached by the CLI. |
| none | `findBufferIndex` | Replaces `bucket.some(b => b.equals(buffer))` (and findIndex). |

#### `packages/merkle-tree/src/lib/compare.ts` to `packages-zig/merkle-tree-zig/src/lib/compare.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `compareTrees` | `compareTrees` |  |
| none | `ICompareResult` | The TypeScript interface of the same name, as a struct. |
| none | `CompareProgressCallback` | The `(progress: string) => void` callback of compareTrees, as a closure. |
| none | `CompareProgressCallback.call` | The `(progress: string) => void` callback of compareTrees, as a closure. |

#### `packages/merkle-tree/src/lib/merkle-diff.ts` to `packages-zig/merkle-tree-zig/src/lib/merkle-diff.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `processRemainingNodes` | `processRemainingNodes` |  |
| `findDifferingNodes` | `findDifferingNodes` |  |
| `findMerkleTreeDifferences` | `findMerkleTreeDifferences` |  |
| none | `MerkleTreeDiff` | The TypeScript interface of the same name, as a struct. |

#### `packages/merkle-tree/src/lib/merkle-tree.ts` to `packages-zig/merkle-tree-zig/src/lib/merkle-tree.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `findItemInTree` | `findItemInTree` |  |
| `updateNodeInTree` | `updateNodeInTree` |  |
| `combineHashes` | `combineHashes` |  |
| `compareNames` | `compareNames` |  |
| `createLeafNode` | `createLeafNode` |  |
| `createParentNode` | `createParentNode` |  |
| `binaryTreeToArray` | `binaryTreeToArray` |  |
| `arrayToBinaryTree` | `arrayToBinaryTree` |  |
| `rebalanceTree` | `rebalanceTree` |  |
| `rotateRight` | `rotateRight` |  |
| `rotateLeft` | `rotateLeft` |  |
| `_addItem` | `_addItem` |  |
| `createTree` | `createTree` |  |
| `addItem` | `addItem` |  |
| `iterateNodes` | none | Not reached by the CLI. |
| `iterateLeaves` | `iterateLeaves` |  |
| `buildMerkleTree` | `buildMerkleTree` |  |
| `upsertItem` | `upsertItem` |  |
| `updateItem` | `updateItem` |  |
| `getItemInfo` | `getItemInfo` |  |
| `findItemNode` | none | Not reached by the CLI. |
| `splitBigNum` | `splitBigNum` |  |
| `combineBigNum` | `combineBigNum` |  |
| `serializeMerkleNodeV5` | `serializeMerkleNodeV5` |  |
| `serializeMerkleNode` | none | Not reached by the CLI: trees are saved in the current format, which does not use it. |
| `serializeMerkleV5` | `serializeMerkleV5` |  |
| `serializeMerkle` | none | Not reached by the CLI: trees are saved in the current format, which does not use it. |
| `serializeSortTreeV5` | `serializeSortTreeV5` |  |
| `serializeSortNodeV5` | `serializeSortNodeV5` |  |
| `collectStrings` | `collectStrings` |  |
| `collectHashes` | `collectHashes` |  |
| `serializeMerkleTree` | `serializeMerkleTree` |  |
| `rebuildTree` | `rebuildTree` |  |
| `deserializeMerkleNodeV5` | `deserializeMerkleNodeV5` |  |
| `deserializeMerkleNode` | `deserializeMerkleNode` |  |
| `deserializeMerkleV5` | `deserializeMerkleV5` |  |
| `deserializeMerkle` | `deserializeMerkle` |  |
| `deserializeSortNodeV5` | `deserializeSortNodeV5` |  |
| `deserializeSortNode` | `deserializeSortNode` |  |
| `deserializeSortTreeV5` | `deserializeSortTreeV5` |  |
| `deserializeSortTree` | `deserializeSortTree` |  |
| `deserializeMerkleTreeV6` | `deserializeMerkleTreeV6` |  |
| `deserializeMerkleTreeV5` | `deserializeMerkleTreeV5` |  |
| `deserializeMerkleTreeV4` | `deserializeMerkleTreeV4` |  |
| `deserializeMerkleTreeV3` | `deserializeMerkleTreeV3` |  |
| `deserializeMerkleTreeV2` | `deserializeMerkleTreeV2` |  |
| `saveTree` | `saveTree` |  |
| `loadTreeVersion` | `loadTreeVersion` |  |
| `loadTree` | `loadTree` |  |
| `deleteItem` | `deleteItem` |  |
| `_deleteNode` | `_deleteNode` |  |
| `pruneTree` | `pruneTree` |  |
| `deleteItems` | none | Not reached by the CLI (only its tests call it). |
| none | `SortNode` | The TypeScript interface of the same name, as a struct. |
| none | `MerkleNode` | The TypeScript interface of the same name, as a struct. |
| none | `IHashedData` | The TypeScript interface of the same name, as a struct. |
| none | `HashedItem` | The TypeScript interface of the same name, as a struct. |
| none | `IMerkleTree` | The TypeScript interface of the same name, as a struct. |
| none | `CollationElement` | Replaces ICU's collation for `localeCompare(b, undefined, { numeric: true })`: a character or a run of digits. |
| none | `CollationIterator` | Replaces ICU's collation for `localeCompare`: the collation elements of a name. |
| none | `CollationIterator.next` | Replaces ICU's collation for `localeCompare`: the collation elements of a name. |
| none | `decodeCodePoint` | Decodes UTF-8 as a JavaScript string holds it (U+FFFD for invalid bytes). |
| none | `comparePrimaryWeights` | Replaces ICU's collation for `localeCompare`: compares two collation elements. |
| none | `Utf16Iterator` | Replaces the UTF-16 code units of a JavaScript string. |
| none | `Utf16Iterator.next` | Replaces the UTF-16 code units of a JavaScript string. |
| none | `lessThanUtf16` | Replaces the order of `Array.prototype.sort()` for strings (UTF-16 code units). |
| none | `FlatSortNode` | `Omit<SortNode, 'minName'>`, the node of the flat arrays of version 2 and 3 files. |
| none | `requireChild` | Replaces reading a property of a missing child (`node.left!.leafCount`), which throws. |
| none | `NodeIterator` | The generator iterateLeaves returns, as an iterator. |
| none | `SplitNumber` | The `{ high, low }` object of splitBigNum and combineBigNum. |
| none | `validateUuid` | Replaces the `uuid` package's validate. |
| none | `parseUuid` | Replaces the `uuid` package's parse. |
| none | `stringifyUuid` | Replaces the `uuid` package's stringify. |

#### `packages/merkle-tree/src/lib/traverse.ts` to `packages-zig/merkle-tree-zig/src/lib/traverse.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `traverseTreeSync` | `traverseTreeSync` |  |
| `traverseTreeAsync` | `traverseTreeAsync` |  |

#### `packages/merkle-tree/src/lib/visualize.ts` to `packages-zig/merkle-tree-zig/src/lib/visualize.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `visualizeSortTree` | `visualizeSortTree` |  |
| `visualizeMerkleTree` | `visualizeMerkleTree` |  |
| `visualizeTree` | `visualizeTree` |  |
| none | `writeShortHash` | `hashHex.substring(0, 2) + hashHex.substring(hashHex.length - 2)`. |
| none | `writeMetadataValue` | `${value}` of a database metadata value. |
| none | `writeRule` | `"=".repeat(50) + "\n"`. |

<!-- end tables -->

## task-queue

`packages/task-queue` to `packages-zig/task-queue-zig`. Zig only: `json-value.zig`. `worker-queue-backend.ts` has no Zig file: Zig workers are threads sharing the CLI's queue backend.

<!-- tables: packages/task-queue task-queue.txt -->

#### `packages/task-queue/src/index.ts` to `packages-zig/task-queue-zig/src/index.zig`

Types and re-exports only: nothing of it is left in the bundled CLI.


#### `packages/task-queue/src/lib/job-progress.ts` to `packages-zig/task-queue-zig/src/lib/job-progress.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `sendJobProgress` | `sendJobProgress` |  |
| none | `jobTagToJson` | The IJobTag object of the message, as JSON.stringify writes it. |

#### `packages/task-queue/src/lib/pending-task-queue.ts` to `packages-zig/task-queue-zig/src/lib/pending-task-queue.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `resolveTaskPriority` | `resolveTaskPriority` |  |
| `insertTaskByPriority` | `insertTaskByPriority` |  |
| none | `priorityOf` | Reads the priority of a pending task, which a Zig pool keeps in its own record of the task. |

#### `packages/task-queue/src/lib/queue-backend.ts` to `packages-zig/task-queue-zig/src/lib/queue-backend.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `setQueueBackend` | `setQueueBackend` |  |
| `getQueueBackend` | `getQueueBackend` |  |
| none | `IQueueBackend` | The TypeScript interface of the same name, as a struct. |
| none | `IQueueBackend.addTask` | The dispatch of the IQueueBackend interface method of the same name. |
| none | `IQueueBackend.onTaskAdded` | The dispatch of the IQueueBackend interface method of the same name. |
| none | `IQueueBackend.onTaskComplete` | The dispatch of the IQueueBackend interface method of the same name. |
| none | `IQueueBackend.onTaskMessage` | The dispatch of the IQueueBackend interface method of the same name. |
| none | `IQueueBackend.onAnyTaskMessage` | The dispatch of the IQueueBackend interface method of the same name. |
| none | `IQueueBackend.cancelTasks` | The dispatch of the IQueueBackend interface method of the same name. |
| none | `IQueueBackend.onTasksCancelled` | The dispatch of the IQueueBackend interface method of the same name. |
| none | `IQueueBackend.shutdown` | The dispatch of the IQueueBackend interface method of the same name. |

#### `packages/task-queue/src/lib/task-context.ts` to `packages-zig/task-queue-zig/src/lib/task-context.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `TaskContext` | `TaskContext` |  |
| `TaskContext.constructor` | `TaskContext.init` |  |
| `TaskContext.sendMessage` | `TaskContext.sendMessage` |  |
| `TaskContext.cancel` | `TaskContext.cancel` |  |
| `TaskContext.isCancelled` | `TaskContext.isCancelled` |  |
| none | `SendMessageFn` | The `(message: any) => void` constructor argument, as a closure. |
| none | `SendMessageFn.call` | The `(message: any) => void` constructor argument, as a closure. |
| none | `TaskContext.taskContext` | The ITaskContext interface of the context. |
| none | `TaskContext.sendMessageErased` | The vtable entry of sendMessage. |
| none | `TaskContext.isCancelledErased` | The vtable entry of isCancelled. |

#### `packages/task-queue/src/lib/task-queue.ts` to `packages-zig/task-queue-zig/src/lib/task-queue.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `TaskQueue` | `TaskQueue` |  |
| `TaskQueue.constructor` | `TaskQueue.init` |  |
| `TaskQueue.resolveAllWaiters` | `TaskQueue.resolveAllWaiters` |  |
| `TaskQueue.addTask` | `TaskQueue.addTask` |  |
| `TaskQueue.onTaskComplete` | `TaskQueue.onTaskComplete` |  |
| `TaskQueue.onTaskMessage` | `TaskQueue.onTaskMessage` |  |
| `TaskQueue.onAnyTaskMessage` | `TaskQueue.onAnyTaskMessage` |  |
| `TaskQueue.awaitAllTasks` | `TaskQueue.awaitAllTasks` |  |
| `TaskQueue.awaitTask` | `TaskQueue.awaitTask` |  |
| `TaskQueue.notifyCompletionCallbacks` | `TaskQueue.notifyCompletionCallbacks` |  |
| `TaskQueue.notifyMessageCallbacks` | `TaskQueue.notifyMessageCallbacks` |  |
| `TaskQueue.shutdown` | `TaskQueue.shutdown` |  |
| none | `QueueEventKind` | Replaces the JavaScript event loop: a completion or a message delivered by the backend, dispatched by the thread that awaits. |
| none | `IQueueEvent` | The TypeScript interface of the same name, as a struct. |
| none | `IAwaitAllResolver` | The TypeScript interface of the same name, as a struct. |
| none | `IAwaitTaskResolver` | The TypeScript interface of the same name, as a struct. |
| none | `ICompletionCallbackRegistration` | The TypeScript interface of the same name, as a struct. |
| none | `IMessageCallbackRegistration` | The TypeScript interface of the same name, as a struct. |
| none | `IAnyMessageCallbackRegistration` | The TypeScript interface of the same name, as a struct. |
| none | `TaskQueue.deinit` | Zig plumbing: frees what the struct owns (garbage collected in TypeScript). |
| none | `TaskQueue.lock` | Guards the queue's state, which backend callbacks reach from worker threads. |
| none | `TaskQueue.unlock` | Guards the queue's state, which backend callbacks reach from worker threads. |
| none | `TaskQueue.onBackendTaskAdded` | The onTaskAdded arrow function of the constructor. |
| none | `TaskQueue.onBackendTaskComplete` | The onTaskComplete arrow function of the constructor. |
| none | `TaskQueue.onBackendAnyTaskMessage` | The onAnyTaskMessage arrow function of the constructor. |
| none | `TaskQueue.onBackendTasksCancelled` | The onTasksCancelled arrow function of the constructor. |
| none | `TaskQueue.queueEvent` | Replaces the JavaScript event loop: queues a backend event for the thread that awaits. |
| none | `TaskQueue.unsubscribeCompletionCallback` | The unsubscribe arrow function onTaskComplete returns. |
| none | `TaskQueue.unsubscribeMessageCallback` | The unsubscribe arrow function onTaskMessage returns. |
| none | `TaskQueue.unsubscribeAnyMessageCallback` | The unsubscribe arrow function onAnyTaskMessage returns. |
| none | `TaskQueue.waitUntilResolved` | Replaces awaiting a promise: runs queued events until the waiter is resolved. |
| none | `TaskQueue.dispatchEvent` | Replaces the JavaScript event loop: runs the callbacks of one event. |

#### `packages/task-queue/src/lib/types.ts` to `packages-zig/task-queue-zig/src/lib/types.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| none | `ITaskContext` | The TypeScript interface of the same name, as a struct. |
| none | `ITaskContext.sendMessage` | The dispatch of the ITaskContext interface method of the same name. |
| none | `ITaskContext.isCancelled` | The dispatch of the ITaskContext interface method of the same name. |
| none | `TaskPriority` | The TypeScript enum of the same name. |
| none | `TaskPriority.toString` | The string value of the enum member. |
| none | `TaskStatus` | The TypeScript enum of the same name. |
| none | `TaskStatus.toString` | The string value of the enum member. |
| none | `ITask` | The TypeScript interface of the same name, as a struct. |
| none | `ITaskError` | The TypeScript interface of the same name, as a struct. |
| none | `ITaskResult` | The TypeScript interface of the same name, as a struct. |
| none | `WorkerTaskCompletionCallback` | The TypeScript type of the same name, as a closure. |
| none | `WorkerTaskCompletionCallback.call` | The TypeScript type of the same name, as a closure. |
| none | `ITaskMessageData` | The TypeScript interface of the same name, as a struct. |
| none | `TaskMessageCallback` | The TypeScript type of the same name, as a closure. |
| none | `TaskMessageCallback.call` | The TypeScript type of the same name, as a closure. |
| none | `UnsubscribeFn` | The TypeScript type of the same name, as a closure. |
| none | `UnsubscribeFn.call` | The TypeScript type of the same name, as a closure. |
| none | `IJobTag` | The TypeScript interface of the same name, as a struct. |
| none | `IJobProgressMessage` | The TypeScript interface of the same name, as a struct. |
| none | `IMessageCallbackEntry` | The TypeScript interface of the same name, as a struct. |
| none | `TaskAddedCallback` | The `(taskId: string) => void` callback of onTaskAdded, as a closure. |
| none | `TaskAddedCallback.call` | The `(taskId: string) => void` callback of onTaskAdded, as a closure. |
| none | `TasksCancelledCallback` | The `() => void` callback of onTasksCancelled, as a closure. |
| none | `TasksCancelledCallback.call` | The `() => void` callback of onTasksCancelled, as a closure. |
| none | `messageTypeOf` | `message && typeof message === "object" && "type" in message ? message.type : undefined` in notifyMessageCallbacks. |

#### `packages/task-queue/src/lib/worker-queue-backend.ts` to no Zig file

No Zig file: Zig workers are threads of the CLI's process and share its queue backend, so there is no worker-side backend posting to the main process.

| TypeScript | Zig | Notes |
|---|---|---|
| `WorkerQueueBackend` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.constructor` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.addTask` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.onTaskAdded` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.onTaskComplete` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.onTaskMessage` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.onAnyTaskMessage` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.cancelTasks` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.onTasksCancelled` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.shutdown` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.notifyTaskCompleted` | none | No counterpart (see the file note). |
| `WorkerQueueBackend.notifyTaskMessage` | none | No counterpart (see the file note). |

#### `packages/task-queue/src/lib/worker.ts` to `packages-zig/task-queue-zig/src/lib/worker.zig`

| TypeScript | Zig | Notes |
|---|---|---|
| `registerHandler` | `registerHandler` |  |
| `getHandler` | `getHandler` |  |
| `getRegisteredHandlerTypes` | `getRegisteredHandlerTypes` |  |
| `executeTaskHandler` | `executeTaskHandler` |  |

#### Zig files with no TypeScript file

| Zig file | What it is |
|---|---|
| `packages-zig/task-queue-zig/src/lib/json-value.zig` | Replaces the implicit copies JavaScript makes of task data, results and messages (structured clone): an explicit deep copy. |

<!-- end tables -->

## Divergences fixed

Each was found by reading the two side by side, pinned by a unit test that failed before the fix, and fixed in the Zig.

### storage

1. `walkDirectory` kept listing when a listing returned an empty continuation token. TypeScript's `while (next)` ends
   on `""`, which is falsy. Test: `walkDirectory stops listing on an empty continuation token`.
2. `CloudStorage.storedHash` failed on a checksum holding characters outside the base64 alphabet. TypeScript's
   `Buffer.from(checksum, "base64")` never fails: it skips such characters and stops at `=`. `bufferFromBase64` now
   decodes the same way. Tests: `storedHash decodes a checksum the way Buffer.from does, skipping characters that are
   not base64` and `bufferFromBase64 decodes like Buffer.from`.
3. Reading a lock file trimmed only ASCII whitespace, where TypeScript's `lockContent.trim()` also removes a byte
   order mark, a no-break space and the other Unicode spaces. A lock file surrounded by them was broken as corrupt
   instead of being held. The new `utils-zig` `js_string.trim` removes exactly what `String.prototype.trim` does.
   Tests: `a lock file surrounded by Unicode whitespace is read and held, not broken`, and the `js-string` tests.

### bdb

4. The four listing loops of bdb (`BsonDatabase.collections`, `BsonCollection.iterateShards`, `listShards` and
   `listCollections`) kept listing after an empty continuation token, where TypeScript's `while (next)` stops. Tests:
   the four tests of `continuation-token.test.zig`.
5. `BsonCollection.getAll` read its continuation token with a digits-only parser that gave up on a sign, where
   TypeScript uses `parseInt`: "-2" now starts two (empty) shards before the first, as in TypeScript, and the token
   is a JavaScript number throughout. The new `utils-zig` `js_number.parseInt` is a full port of `parseInt`. Tests:
   `getAll reads its continuation token like parseInt` and the `js-number` tests.
6. `stringToNumber` (`Number(string)`, used when a sort index compares numbers) trimmed only ASCII, the no-break
   space, the byte order mark and the line separators, missing the other Unicode space separators. It now uses the
   `utils-zig` `js_string` whitespace. Test: `stringToNumber trims the Unicode space separators like Number(string)`.
7. The entry and page counts of a sort index were `u32`, so a count going below zero (an index file whose count is
   short) crashed the process with an integer overflow. In TypeScript they are numbers that go negative and are
   refused at commit by `writeUInt32` with a RangeError. They are `i64` now, and `serialization.checkUInt32` gives
   the same RangeError. Tests: `a count that goes below zero is refused at commit like writeUInt32 refuses it` and
   `checkUInt32 accepts 0 to 4294967295 and refuses anything else like writeUInt32LE`.

### api and lan-share-core

8. `resolveDatabaseSharePayload` threw when shared S3 credentials had no region (or no key), where TypeScript sends
   the payload with the field undefined, and the receiver stores the credentials without it. The fields are optional
   in `IShareS3Credentials` now. Tests: `S3 credentials without a region are shared without one` (which replaced a
   Zig test that pinned the error) and `an S3 region that is absent is left out of the stored value`.
9. `streamAssetToFile` (the MCP `save_media_file` tool) left no output file when the asset was missing. In
   TypeScript the file storage opens its read stream lazily, after `createWriteStream` has made the output file, so
   the call fails with an empty output file left behind. The Zig now makes the output file first. Test:
   `streamAssetToFile fails for a missing asset after creating the output file, like TypeScript`.

### utils and node-utils

10. `formatFileSize` crashed (index out of bounds) from a petabyte up, where TypeScript reads `sizes[5]` and prints
    "undefined" as the unit. Test: `formatFileSize names the unit undefined from a petabyte up, like TypeScript`.
11. `parseFloat` (used for video rotation and ffprobe numbers) skipped only ASCII whitespace; it moved to
    `js_number` and skips all JavaScript whitespace. Test: `parseFloat skips Unicode whitespace before the number`.
12. `parseXdgPicturesDir` trimmed lines and matched `\s` with ASCII whitespace only, where `trim()` and `\s` also
    take the Unicode spaces and line separators. Test: `treats Unicode spaces around the key and the value as
    whitespace`.

### node-api, tools and apps/cli

13. A file's modified time was rounded down to whole milliseconds, where a JavaScript Date truncates `mtimeMs`
    towards zero, so a file modified before 1970 was a millisecond out (Bun: `mtimeMs` -1000.5, `getTime()` -1000).
    Fixed in the file scanner, `updateFileOptimistic`'s fingerprint (node-utils), `psi hash-cache add` and the log
    file order of `psi bug`. Tests: `a modified time before 1970 is truncated to whole milliseconds like a JavaScript
    Date` and the before-1970 case of `hash-cache hash-file and add hash a file like the TypeScript CLI`.
14. The zip progress name, `rootZipName.substring(0, 50)`, dropped a character cut in half at the 50th code unit,
    where JavaScript keeps its high surrogate and prints it as U+FFFD. Test: `a zip name cut through a character
    outside the Basic Multilingual Plane is reported with U+FFFD`.
15. `parseExifDate` trimmed ASCII whitespace only (`trim()` also removes the Unicode spaces and the byte order mark),
    and accepted the years 1 to 99, which `Date.UTC` reads as 1901 to 1999 so the round trip check refuses them. Tests:
    `parseExifDate ignores surrounding whitespace that is not ASCII, as String.prototype.trim does` and `parseExifDate
    refuses the years 1 to 99, which Date.UTC reads as 1901 to 1999`.
16. The out of range GPS log line printed coordinates with Zig's number formatting (`0.0000001` for `1e-7`). Test:
    `locationJson prints numbers as JSON.stringify does`.
17. A video's JSON sidecar timestamp: an array or object failed the import (`Unsupported JSON value`) where
    `parseInt` reads `String(value)` and an unusable date is caught and logged; `0x10` read as 0 where `parseInt`
    reads 16; and a timestamp too large for a Date crashed the process in `@intFromFloat` where dayjs throws a
    RangeError that is caught. Tests: `a JSON timestamp is read as JavaScript's parseInt reads it` and `a JSON
    timestamp that is not a number leaves the video undated rather than failing it`.
18. tools-zig had its own `parseInt` (ASCII whitespace, no `0x`, digits accumulated in a float so a long number
    rounded differently). It is gone: tools, `psi list` and `psi hash-cache` use `utils-zig` `js_number.parseInt` with
    the radix the TypeScript passes (none in tools, 10 in the CLI commands).
19. `psi hash-cache set` let a length of 2 ** 48 or more through to the cache, which then refused it with the number
    printed as an integer (`18446744073709549568`), where `writeUIntLE` refuses it with the number printed as
    JavaScript prints it (`18446744073709550000`, `1.2345678901234568e+29`). Test: the new cases of `cachedLength
    stores a length like writeUIntLE(parseInt(length, 10), offset, 6)`.
20. The news feed's `fileURLToPath` kept a query and fragment in the path, did not resolve `.` and `..`, took a
    backslash literally, ignored a host, and decoded `%2F`. It now parses the URL as Bun's `fileURLToPath` does, with
    its TypeErrors for a host and an encoded slash. Test: `fileURLToPath parses the URL first, as Bun's fileURLToPath
    does`.
21. A news link label or url that is not a string printed with Zig's number formatting, and an array as nothing, where
    the template string prints `1e+21` and `1,,b`. Test: `a link label that is not a string is printed as a
    JavaScript template string prints it`.
22. The names in a comma-separated `--key` were trimmed of ASCII whitespace only. Test: `comma-separated
    encryptionKey names are trimmed of the whitespace String.prototype.trim removes`.
23. The paths of databases.toml and state.yaml were joined without `path.join`'s normalization, so a
    PHOTOSPHERE_CONFIG_DIR with `.` or `..` in it gave a different path. `getDatabasesConfigPath` is ported so the
    path can be read. Test: `the paths of databases.toml and state.yaml are joined and normalized as path.join does`.
24. `psi verify`'s progress messages were cut at 1024 bytes, so a long `--path` filter was shown truncated. Test:
    `verify reports a long path filter in full`.
25. `verifyFileHandler` threw Node's message for `Buffer.compare` with no hash to compare against, where Bun says
    `The "buf2" argument must be of type Buffer or Uint8Array. Received undefined` with the name TypeError. Test:
    `verifyFileHandler fails like Buffer.compare in Bun for a changed file whose node has no content hash`.
26. `upload-asset` read the upload date before uploading the files, where the TypeScript reads it when it builds the
    record, after them, so the recorded date was early by the length of the upload. Test: `the upload date is read
    once the files are uploaded, as the TypeScript builds the record after them`.

### node-utils, and JSON read by api and node-api

27. The YAML loader did not read literal and folded block scalars (`|` and `>`), which js-yaml's `dump` writes for a
    string longer than 80 characters or holding a line break, so state.yaml with such a value (a long path) could not
    be read back. It is a port of js-yaml's `readBlockScalar` now, chomping and indentation indicators included. Tests:
    `load reads literal and folded block scalars like js-yaml` and the dump and load round trip of long and multi-line
    strings.
28. A JSON object with a repeated key was refused (`DuplicateField`) where `JSON.parse` keeps the last value: in
    readJson, a database's `.db/config.json`, the import record and the S3 credentials stored in the vault (both where
    the CLI resolves them and where a LAN share sends them). Tests: `readJson keeps the last value of a repeated key,
    as JSON.parse does`, the repeated key cases of the database config and import record tests, and `an S3 secret with
    a repeated key is read with its last value, as JSON.parse reads it` (api and node-api).
29. `exec` had no output limit, where Bun's `child_process.exec` kills a command that writes more than 1 MiB
    (`maxBuffer`) to stdout or stderr and fails with the RangeError `stdout maxBuffer length exceeded`. Tests: `exec
    takes up to maxBuffer (1 MiB) of output, as Bun's exec does` and `exec fails with Bun's RangeError when the command
    writes more than maxBuffer to stdout or stderr`. The Windows branch is compiled for Windows but not run here.
30. `os.homedir` returned an empty string when HOME was unset or empty, where Bun falls back to the passwd entry, so
    `psi` run without HOME put databases.toml and the hash cache under `.` instead of the user's home. Tests: `osHomedir
    falls back to the passwd entry when HOME is unset or empty, as Bun's os.homedir does`, and the no home directory
    cases of getConfigDir and getCacheDir, which now expect the passwd entry's home everywhere but Windows.
31. The test UUID generator (NODE_ENV=testing) read its counter file with an ASCII trim and a saturating integer, and
    joined its path without `path.join`'s normalization. It now trims as `String.prototype.trim` does, parses with
    `parseInt(text, 10) || 0` and counts in a JavaScript number, written back as `String()` writes it. Tests: `the
    counter file is read with String.prototype.trim and parseInt, as TypeScript reads it`, `a counter past the
    integers a double holds exactly counts on as a JavaScript number` and `the counter directory defaults to
    ./test/tmp`.
32. `parseXdgPicturesDir` matched a value holding `\r`, U+2028 or U+2029, which `.` in the regular expression does
    not match. Test: `a value holding a line terminator does not match, as in the TypeScript regular expression`.
33. The unhandled rejection a signal shutdown ends in (its callbacks threw twice) logged the thrown error itself,
    where the handler logs `new Error(reason)`, whose message is `String(reason)`: `Error: <message>`. Test: `the
    unhandled rejection of a failed signal shutdown logs the thrown error as new Error(reason) does`.

### utils, encryption and vault

34. `String(error)` in a template string (`Failed to get EXIF data: ${error}` and the other tools messages, and
    getFileInfo's) and the first line of the stack in retry's last error log were written `Error: <message>` whatever
    the error was, where JavaScript writes the error's own name (`RangeError`, `FatalError`). `errors.errorToString`
    and `errors.errorName` give it now. Tests: `errorToString gives String(error): the name JavaScript gives the error
    and its message` and `the last error is reported with its own name, as the first line of its stack shows it`.
35. `Date.toISOString` crashed (`@intCast` of a negative year) for a time before the year 0 and wrote a year after
    9999 in five digits, where JavaScript writes `-000001` and `+010000`; a time past 8.64e15 milliseconds is a
    RangeError `Invalid Date`. It is reached with file modified times (`psi hash`, `psi hash-cache`, the check task).
    Test: `Date.toISOString writes years outside 0 to 9999 in the expanded form and refuses an invalid time, as
    JavaScript does`.
36. Reverse geocoding wrote coordinates with Zig's number formatting (`1000000000000000000000` for `1e+21`) in its
    error messages and request URL, refused a response that was not JSON where axios hands back the text (so no
    location), refused a repeated key where JSON.parse keeps the last, and threw `TypeError: Cannot read properties
    of null` as an Error where Bun throws the TypeError `null is not an object (evaluating 'data.status')`. Tests: `a
    coordinate is written in the error message as a template string writes a number` and `the response body is read
    as axios reads it: JSON.parse, or the text itself when it is not JSON`. The null response branch is not covered
    by a unit test: reaching it needs a server answering `null`.
37. `getImageTransformation` crashed (`@intFromFloat`) for an unknown orientation from 2 ** 63 up to 1e21 and wrote
    small ones in fixed notation. Test: `getImageTransformation writes a large or small unknown orientation as
    String(number) does`.
38. The encryption type field of an encrypted file header was read byte for byte, where `toString("ascii")` drops
    the high bit of each byte, so a header whose type bytes had the high bit set was refused where TypeScript reads
    `A2CB`. Test: `normalizeEncryptionType decodes the field as Buffer.toString("ascii") does, dropping the high bit of
    each byte`.
39. The keychain vaults trimmed command output and `secret-tool` attribute lines of ASCII whitespace only, and the
    macOS and Windows vaults refused a stored payload with a repeated key. Tests: `runCommand trims stdout and stderr
    as String.prototype.trim does, Unicode spaces included`, `parseSearchOutput trims lines and values as
    String.prototype.trim does, Unicode spaces included` and the repeated key tests of the macOS and Windows vaults.
40. The plaintext vault's default directory read HOME alone, so with HOME unset the vault moved to
    `.config/photosphere/vault` under the current directory, and its paths were joined without `path.join`'s
    normalization. Tests: `DEFAULT_VAULT_DIR is under the home directory os.homedir gives, the passwd entry's when HOME
    is unset` and `getVaultFilePath joins and normalizes the path as path.join does`.

### lan-share-network and serialization

41. The LAN share sender refused a /pairing-code-hash response whose `codeHash` was missing or not a string, and one
    with a repeated key, with a JSON error, where TypeScript reads `codeHash` (the last of a repeated key) and
    answers false when it is not the code hash, and throws the TypeError `null is not an object` for a body of
    `null`. Test: `the pairing code hash response is read as JSON.parse reads it`.
42. The announced port was read with an ASCII trim and no sign, where `parseInt(text, 10)` skips every JavaScript
    whitespace character and takes a sign. Test: `the announced port is read as parseInt(text, 10) reads it`.
43. The LAN share receiver handed a falsy payload (`false`, `0`, `""`) to `psi dbs receive` and `psi secrets
    receive` as a payload, where their `if (!rawPayload)` treats it as nothing received; only `null` was treated
    so. Test: `a falsy payload is received as no payload, as the callers' \`if (!rawPayload)\` reads it`. The receiver
    also answered a /share-payload body with a repeated key `Invalid JSON` where JSON.parse keeps the last value;
    that is fixed too, but the unit tests have no client that can send a repeated key, so it is not covered.
44. `load` compared a file's type code byte for byte, where `toString('ascii')` drops the high bit of each byte, so a
    file whose type code bytes had the high bit set was read as a legacy file instead. Test: `the type code is read
    as toString("ascii") reads it, which drops the high bit of each byte`.

## Divergences kept

1. `FileStorage.acquireWriteLock` (storage): an empty lock file younger than the lock timeout is refused
   (`ACQUIRE_FAILED_BEING_WRITTEN`) instead of being broken as corrupt. The TypeScript has the same race (see
   "TypeScript bugs"), and the Zig unit test ported from `file-storage-locks.test.ts` ("should handle race conditions
   properly") failed on macOS CI because of it: two of three contenders got the lock. Removing the fix to match the
   TypeScript would bring that failure back, so it stays until the TypeScript is fixed the same way.

2. `LazyOriginStorage.readStream` (node-api, used by `psi export` on a partial replica): when caching the fetched
   file locally fails, the Zig stops feeding the cache and hands the caller the whole file. The TypeScript hangs (see
   "TypeScript bugs"). Matching it would make `psi export` hang, so the Zig keeps working; test: `readStream() streams
   a file larger than the cache queue in full when the local cache write fails`.

3. The LAN share receiver (lan-share-network) answers a /share-payload body of `null` with 403 Invalid pairing code.
   The TypeScript reads `parsed.codeHash` of null inside the request's 'end' handler, which throws an uncaught
   TypeError and ends the receiving process. Matching it would let any device on the LAN stop a `psi dbs receive`
   with one request, so the Zig keeps answering 403 (see "TypeScript bugs").

## TypeScript bugs noted

1. `FileStorage.acquireWriteLock` creates the lock file with `flag: 'wx'` and writes its JSON in the same call, but
   the file exists and is empty between the create and the write. A second contender that reads it then cannot parse
   it, takes it for a corrupt lock, deletes it and creates its own, so both hold the lock.
2. `CloudStorage.dirExists` has a branch for an empty key that can never run: `parsePath` throws for an empty key
   before it is reached.
3. `LazyOriginStorage.readStream` hangs when the local cache write fails before reading everything: nothing drains
   `cacheStream` any more, so once its buffer is full the origin stays paused and `callerStream` never ends. Run in Bun
   with a cache write that rejects and a 192 KB file, the caller stops after 65536 bytes. The existing unit test uses
   a file small enough to fit the buffer.
4. `import-assets` logs `File "" is a duplicate in this scan, skipping.`: the template string lost its
   `${logicalPath}`. The Zig logs the same text.
5. `LanShareReceiver` (lan-share-network): a /share-payload body of `null` makes the request's 'end' handler throw
   an uncaught TypeError (`parsed.codeHash` of null), which ends the receiving process.

## JavaScript behaviour not emulated

Places where the Zig does not reproduce the JavaScript runtime, each with its reason. They are still divergences and
are listed so a reviewer does not have to find them again. Most are JavaScript's dynamic typing of data read from a
file only psi writes: the Zig reads the data as the type psi writes and fails loudly on anything else. Two (collation
and case mapping of non-ASCII text) need the Unicode tables of ICU, which the Zig does not link.

1. A lock file whose JSON is valid but has fields of other types (a missing `owner`, a string `timestamp`, an
   `acquiredAt` that is not `toISOString` output). TypeScript carries `undefined`, `NaN` or an Invalid Date forward;
   the Zig treats the lock file as unreadable (`FileStorage` breaks it as corrupt, `CloudStorage` throws the
   `Failed to check write lock` error).
2. Collation of non-ASCII names (`locale-compare.zig`): characters outside ASCII sort by code point after all ASCII
   characters, where ICU sorts them by its collation table (for example "é" next to "e"). The names storage lists and
   the merkle tree sorts are asset ids and database file names, which are ASCII.
3. Unicode case mapping in `searchAssets` (the MCP `search_media_files` tool): `toLowerCase` lowercases ASCII letters
   only, where JavaScript lowercases every letter with a lowercase form, so a query and a file name that differ only in
   the case of a non-ASCII letter ("É" and "é") match in TypeScript and not in Zig.
4. Records holding values of types the bdb code never writes (for example a string where the merge expects a
   metadata object): the Zig throws an error naming the value's type, where JavaScript carries it through.
5. `retryOnce` cancels an operation that times out; TypeScript leaves it running in the background, since a promise
   cannot be cancelled. Its error log has the error's name and message but no stack.
6. `BsonCollection.insertOne` with an `_id` that is not a string: TypeScript keeps a truthy non-string id (and then
   fails in `getShardId`), the Zig replaces it with a new UUID.
7. Error messages of the file system and of `JSON.parse`: where the Zig emulates Node's message it does so for a
   missing file (`ENOENT: no such file or directory, open '...'`); other file system errors (permission denied, not a
   directory) show the Zig error name, and a malformed JSON document shows `JSON Parse error:` and the Zig error name
   rather than JavaScriptCore's description.
8. Key order of objects: JavaScript lists integer-like keys first, in numeric order, then the others in insertion
   order. The Zig keeps insertion order, which differs only for integer-like keys (the `ui` section of state.yaml,
   whose keys the desktop interface chooses).
9. `verify-file`'s `toLocaleString` of the old and new modified times (a verbose log line) is en-US in UTC, where
   JavaScript uses the machine's time zone and locale.
10. File names that are not valid UTF-8: Node decodes them to U+FFFD, the Zig keeps the bytes (the hash cache keys and
    the zip entry names likewise).
11. Values of the wrong type in files psi writes, as in item 1: `filesImported` that is not a whole number (read as
    0 or truncated where JavaScript carries it through, and a string grows by concatenation there), `deletedAssetIds`
    that is not a list of strings (the Zig throws), non-string `recent_database_names` (dropped) and a database entry
    without a name.
12. `loadSharedHashCache` compares the cache file's modified time in nanoseconds where TypeScript compares
    `mtimeMs`, a double that cannot tell apart two times less than about a quarter of a microsecond apart. Either way
    the cache is re-read when the file changes.
13. `iterateLeaves` in sync.zig accepts a leaf with an empty name, where `!node.name` throws; merkle tree leaves are
    record, shard and collection names, which are never empty.
14. js-yaml features psi never writes: anchors, aliases, tags, plain scalars that go on over several lines and
    documents of more than one part. The Zig loader throws a YAMLException for them where js-yaml reads them.
15. `exec` gives the command an empty stdin where Node gives it an open pipe that nothing writes to, so a command
    that reads stdin ends at once in the Zig and waits for ever in TypeScript. The commands psi runs (magick, ffprobe,
    ffmpeg) read no stdin.
16. `os.homedir` on Windows reads USERPROFILE only, where Bun falls back to the profile directory Windows reports;
    Windows always sets USERPROFILE.
17. `String(value)` of an orientation that is a Date: JavaScript writes the date (`Thu Jan 01 1970 ...`), the Zig
    writes `date`. exif-parser gives numbers.
18. `getVideoTransformation` with `streams` that is not an array: `for...of` throws a TypeError for a value that is
    not iterable, the Zig returns no transformation. ffprobe's JSON always has an array.
19. Keys that are not RSA: `createPrivateKey` and `createPublicKey` accept any key type, and encryption fails later
    with OpenSSL's message; the Zig refuses the key when it is loaded (`error:1E08010C:DECODER routines::unsupported`).
20. `runCommand` in the keychain vaults closes the child's stdin, where TypeScript leaves the pipe open; the security,
    secret-tool and PowerShell commands psi runs read no stdin (secret-tool store gets its secret and then end of input
    in both).
21. An announced LAN share port that is not a port (negative or past 65535): TypeScript takes the receiver and then
    fails to connect, the Zig ignores the announcement and keeps listening.
22. A merkle tree leaf's modified time past what a Date holds (8.64e15 milliseconds) is an Invalid Date in TypeScript;
    the Zig keeps the number (a time of 2 ** 63 milliseconds or more reads as negative). psi writes real modified
    times.
