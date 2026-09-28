# Zig port map

Every TypeScript source file the `psi` CLI bundles, the Zig file that ports it, and every TypeScript function with
the Zig function that ports it. Use it to read the two side by side: the Zig files have the same names and the same
function order as the TypeScript ones.

**Progress of the side by side comparison:** storage done. Still to do: bdb, api, node-utils, node-api, encryption,
lan-share, utils and the smaller packages, apps/cli.

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

These are places where the TypeScript relies on JavaScript's dynamic typing of data read from a file only psi writes.
The Zig reads the data as the type psi writes and fails loudly on anything else.

1. A lock file whose JSON is valid but has fields of other types (a missing `owner`, a string `timestamp`, an
   `acquiredAt` that is not `toISOString` output). TypeScript carries `undefined`, `NaN` or an Invalid Date forward;
   the Zig treats the lock file as unreadable (`FileStorage` breaks it as corrupt, `CloudStorage` throws the
   `Failed to check write lock` error).
2. Collation of non-ASCII names (`locale-compare.zig`): characters outside ASCII sort by code point after all ASCII
   characters, where ICU sorts them by its collation table (for example "é" next to "e"). The names storage lists and
   the merkle tree sorts are asset ids and database file names, which are ASCII.
