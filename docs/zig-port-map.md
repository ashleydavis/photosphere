# Zig port map

Every TypeScript source file the `psi` CLI bundles, the Zig file that ports it, and every TypeScript function with
the Zig function that ports it. Use it to read the two side by side: the Zig files have the same names and the same
function order as the TypeScript ones.

**Progress of the side by side comparison:** storage, bdb, api and lan-share-core done. Still to do: node-utils,
node-api, encryption, lan-share-network, utils, serialization and the other smaller packages, apps/cli.

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

## Divergences kept

1. `FileStorage.acquireWriteLock` (storage): an empty lock file younger than the lock timeout is refused
   (`ACQUIRE_FAILED_BEING_WRITTEN`) instead of being broken as corrupt. The TypeScript has the same race (see
   "TypeScript bugs"), and the Zig unit test ported from `file-storage-locks.test.ts` ("should handle race conditions
   properly") failed on macOS CI because of it: two of three contenders got the lock. Removing the fix to match the
   TypeScript would bring that failure back, so it stays until the TypeScript is fixed the same way.

## TypeScript bugs noted

1. `FileStorage.acquireWriteLock` creates the lock file with `flag: 'wx'` and writes its JSON in the same call, but
   the file exists and is empty between the create and the write. A second contender that reads it then cannot parse
   it, takes it for a corrupt lock, deletes it and creates its own, so both hold the lock.
2. `CloudStorage.dirExists` has a branch for an empty key that can never run: `parsePath` throws for an empty key
   before it is reached.

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
