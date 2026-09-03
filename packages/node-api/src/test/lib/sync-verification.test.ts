import * as fs from "fs";
import { createHash } from "crypto";
import * as os from "os";
import * as path from "path";
import { createStorage, IStorage, IFileInfo, IListResult, IWriteLockInfo } from "storage";
import type { Readable } from "stream";
import { TestUuidGenerator } from "node-utils";
import { createDatabase, createMediaFileDatabase, writeAsset } from "../../lib/media-file-database";
import { syncDatabases } from "../../lib/sync";
import { loadMerkleTree, saveMerkleTree } from "../../lib/tree";
import type { ITimestampProvider } from "utils";

//
// A clock the test drives rather than the wall clock, so what is being asserted is the sync's
// behaviour and not how fast the test happened to run.
//
class FixedTimestampProvider implements ITimestampProvider {

    //
    // The time every call reports, in milliseconds.
    //
    private current: number;

    //
    // Starts the clock at the given time.
    //
    constructor(start: number) {
        this.current = start;
    }

    //
    // Moves the clock forward.
    //
    advance(milliseconds: number): void {
        this.current += milliseconds;
    }

    //
    // The current time in milliseconds.
    //
    now(): number {
        return this.current;
    }

    //
    // The current time as a Date.
    //
    dateNow(): Date {
        return new Date(this.current);
    }
}

//
// Wraps a real storage, answering storedHash from a map the test controls and counting how many
// times a file is streamed back out of it.
//
// This is what makes the difference observable: a sync that trusts the store's own hash reads
// nothing back, and a sync that does not read the whole file a second time.
//
class HashReportingStorage implements IStorage {

    //
    // The storage every call is passed through to.
    //
    private readonly inner: IStorage;

    //
    // What storedHash answers, by path. A path that is not here answers undefined, which is what a
    // store that keeps no hash of its own says.
    //
    public readonly hashes: Map<string, Buffer>;

    //
    // The paths that were streamed back out, in order, so a test can say a file was not read again.
    //
    public readonly readStreamPaths: string[] = [];

    //
    // Whether writeStreamHashed reports that it checked the bytes, which is what a store that can
    // check them does.
    //
    public verifiesWhatItWrites = false;

    //
    // The paths info() and storedHash() were asked about, so a test can say a verified write cost no
    // further round trips.
    //
    public readonly askedAbout: string[] = [];

    //
    // The hashes handed to writeStreamHashed, by path, so a test can say the sync sent the hash it
    // already had rather than leaving the store to work one out.
    //
    public readonly hashesWrittenWith: Map<string, Buffer> = new Map();

    //
    // Wraps the given storage.
    //
    constructor(inner: IStorage, hashes: Map<string, Buffer>) {
        this.inner = inner;
        this.hashes = hashes;
    }

    get location(): string {
        return this.inner.location;
    }

    async storedHash(filePath: string): Promise<Buffer | undefined> {
        this.askedAbout.push(filePath);
        return this.hashes.get(filePath);
    }

    isEmpty(path: string): Promise<boolean> {
        return this.inner.isEmpty(path);
    }

    listFiles(path: string, max: number, next?: string): Promise<IListResult> {
        return this.inner.listFiles(path, max, next);
    }

    listDirs(path: string, max: number, next?: string): Promise<IListResult> {
        return this.inner.listDirs(path, max, next);
    }

    fileExists(filePath: string): Promise<boolean> {
        return this.inner.fileExists(filePath);
    }

    dirExists(dirPath: string): Promise<boolean> {
        return this.inner.dirExists(dirPath);
    }

    info(filePath: string): Promise<IFileInfo | undefined> {
        this.askedAbout.push(filePath);
        return this.inner.info(filePath);
    }

    read(filePath: string): Promise<Buffer | undefined> {
        return this.inner.read(filePath);
    }

    write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        return this.inner.write(filePath, contentType, data);
    }

    readStream(filePath: string): Promise<Readable> {
        this.readStreamPaths.push(filePath);
        return this.inner.readStream(filePath);
    }

    writeStream(filePath: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength?: number): Promise<void> {
        return this.inner.writeStream(filePath, contentType, inputStream, contentLength);
    }

    async writeStreamHashed(filePath: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength: number, sha256: Buffer): Promise<boolean> {
        this.hashesWrittenWith.set(filePath, sha256);
        await this.inner.writeStreamHashed(filePath, contentType, inputStream, contentLength, sha256);
        return this.verifiesWhatItWrites;
    }

    deleteFile(filePath: string): Promise<void> {
        return this.inner.deleteFile(filePath);
    }

    deleteDir(dirPath: string): Promise<void> {
        return this.inner.deleteDir(dirPath);
    }

    copyTo(srcPath: string, destPath: string): Promise<void> {
        return this.inner.copyTo(srcPath, destPath);
    }

    acquireWriteLock(filePath: string, owner: string): Promise<boolean> {
        return this.inner.acquireWriteLock(filePath, owner);
    }

    releaseWriteLock(filePath: string): Promise<void> {
        return this.inner.releaseWriteLock(filePath);
    }

    checkWriteLock(filePath: string): Promise<IWriteLockInfo | undefined> {
        return this.inner.checkWriteLock(filePath);
    }

    refreshWriteLock(filePath: string, owner: string): Promise<void> {
        return this.inner.refreshWriteLock(filePath, owner);
    }
}

describe("a sync checks its copies against the target's own hash", () => {

    let workingDir: string;

    //
    // The asset the source database holds and the sync has to push.
    //
    const assetId = "11111111-2222-3333-4444-555555555555";
    const assetBytes = Buffer.from("the-bytes-of-a-photo");

    //
    // A second asset, sorted after the first, so a test can say the sync carried on past a file it
    // could not copy.
    //
    const laterAssetId = "99999999-2222-3333-4444-555555555555";
    const laterAssetBytes = Buffer.from("the-bytes-of-another-photo");

    beforeEach(() => {
        workingDir = fs.mkdtempSync(path.join(os.tmpdir(), "psphere-sync-verify-"));
    });

    afterEach(() => {
        fs.rmSync(workingDir, { recursive: true, force: true });
    });

    //
    // Builds a source database holding one asset file, and an empty target replicated from it, and
    // runs a sync between them with the target wrapped so its storedHash answers can be chosen.
    //
    // Returns the wrapper, so a test can read what was streamed back out of the target, and the
    // sync's own promise, so a test can say it failed.
    //
    async function syncOneAsset(targetHashes: Map<string, Buffer>, verifiesWhatItWrites: boolean = false): Promise<{ target: HashReportingStorage, run: Promise<void> }> {
        const clock = new FixedTimestampProvider(Date.parse("2026-01-01T00:00:00.000Z"));

        const sourcePath = path.join(workingDir, "source");
        fs.mkdirSync(sourcePath, { recursive: true });
        const source = createStorage(sourcePath, undefined, undefined);
        const sourceDatabase = createMediaFileDatabase(source.storage, new TestUuidGenerator(), clock);
        await createDatabase(source.storage, source.rawStorage, new TestUuidGenerator(), sourceDatabase.metadataCollection);

        await sourceDatabase.metadataCollection.insertOne({
            _id: assetId,
            origFileName: "test.jpg",
            contentType: "image/jpeg",
        } as any);
        await sourceDatabase.bsonDatabase.commit();
        await writeAsset(source.storage, source.rawStorage, "session-source", assetId, "asset", "image/jpeg", assetBytes);

        await sourceDatabase.metadataCollection.insertOne({
            _id: laterAssetId,
            origFileName: "later.jpg",
            contentType: "image/jpeg",
        } as any);
        await sourceDatabase.bsonDatabase.commit();
        await writeAsset(source.storage, source.rawStorage, "session-source", laterAssetId, "asset", "image/jpeg", laterAssetBytes);

        // The target is a database of its own, holding nothing, carrying the source's database id so
        // the two are related and a sync between them is allowed.
        //
        // Replicating one would not do: a replica arrives with the source's merkle tree, so it claims
        // to hold every file already and the sync copies nothing. Copying the id across is what
        // `replicate --force` does to a destination whose id does not match.
        const targetPath = path.join(workingDir, "target");
        fs.mkdirSync(targetPath, { recursive: true });
        const target = createStorage(targetPath, undefined, undefined);
        const targetDatabase = createMediaFileDatabase(target.storage, new TestUuidGenerator(), clock);
        await createDatabase(target.storage, target.rawStorage, new TestUuidGenerator(), targetDatabase.metadataCollection);

        const sourceTree = await loadMerkleTree(source.storage);
        const targetTree = await loadMerkleTree(target.storage);
        if (!sourceTree || !targetTree) {
            throw new Error("both databases must have a merkle tree before they can be related");
        }
        targetTree.id = sourceTree.id;
        await saveMerkleTree(targetTree, target.storage);

        const reopenedSource = createStorage(sourcePath, undefined, undefined);
        const reopenedSourceDatabase = createMediaFileDatabase(reopenedSource.storage, new TestUuidGenerator(), clock);
        const reopenedTarget = createStorage(targetPath, undefined, undefined);
        const wrappedTarget = new HashReportingStorage(reopenedTarget.storage, targetHashes);
        wrappedTarget.verifiesWhatItWrites = verifiesWhatItWrites;
        const reopenedTargetDatabase = createMediaFileDatabase(wrappedTarget, new TestUuidGenerator(), clock);

        const run = syncDatabases(
            reopenedSource.storage,
            reopenedSource.rawStorage,
            reopenedSourceDatabase.bsonDatabase,
            wrappedTarget,
            reopenedTarget.rawStorage,
            reopenedTargetDatabase.bsonDatabase,
            "session-sync"
        ).then(() => undefined);

        return {
            target: wrappedTarget,
            run,
        };
    }

    test("a target that knows its own hash is not read back", async () => {
        // Reading every copied file back is what made syncing a phone's library unusable: the file
        // crosses the network twice and is hashed by the embedded engine's pure JavaScript SHA-256.
        const hashes = new Map<string, Buffer>([[`asset/${assetId}`, hashOfSourceAsset()]]);

        const { target, run } = await syncOneAsset(hashes);
        await run;

        // Said first, because "it was not read back" is true of a file that was never copied at all.
        expect(await target.fileExists(`asset/${assetId}`)).toBe(true);
        expect(target.readStreamPaths).not.toContain(`asset/${assetId}`);
    });

    test("a store that checked the bytes as it wrote them is asked nothing further", async () => {
        // Asking cost two more round trips per file on top of the write: one to learn the file is
        // there and how long it is, another to read back the hash the server had just verified. On a
        // phone, where every request is a fresh connection and the response crosses the engine
        // bridge, those two were a large part of what a file cost.
        const { target, run } = await syncOneAsset(new Map(), true);
        await run;

        expect(await target.fileExists(`asset/${assetId}`)).toBe(true);
        expect(target.askedAbout).not.toContain(`asset/${assetId}`);
    });

    test("the hash the sync already has goes up with the file", async () => {
        // Nothing should have to compute it. The AWS SDK asked to checksum a body hashes it in the
        // embedded engine's pure JavaScript SHA-256 at well under a megabyte a second, and on a
        // Pixel 6 one 100MB video held the upload for over a quarter of an hour with no byte
        // reaching the server. The merkle tree is made of these hashes, so the sync already has it.
        const { target, run } = await syncOneAsset(new Map());
        await run;

        expect(target.hashesWrittenWith.get(`asset/${assetId}`)).toEqual(hashOfSourceAsset());
    });

    test("a target that does not know its own hash is checked by length, not read back", async () => {
        // Reading a file back to hash it is what made syncing a phone's library impossible: each file
        // crossed the network twice and was hashed by the embedded engine's pure JavaScript SHA-256
        // at well under a megabyte a second. `psi verify` is the deep check.
        const { target, run } = await syncOneAsset(new Map());
        await run;

        expect(await target.fileExists(`asset/${assetId}`)).toBe(true);
        expect(target.readStreamPaths).not.toContain(`asset/${assetId}`);
    });

    test("a file that will not copy is left behind and the rest of the library still goes", async () => {
        // The rest of the library has nothing to do with the bad file, and abandoning the pass on it
        // means everything after it in the tree never goes anywhere: measured on a Pixel 6 against a
        // real library, one video the server kept refusing held up all 2,292 assets, pass after pass.
        const { target, run } = await syncOneAsset(new Map<string, Buffer>([
            [`asset/${assetId}`, Buffer.alloc(32, 9)],
            [`asset/${laterAssetId}`, hashOf(laterAssetBytes)],
        ]));

        await run;

        expect(await target.fileExists(`asset/${laterAssetId}`)).toBe(true);
    });

    //
    // The hash the source database recorded for its asset, which is what a correct copy must match.
    //
    function hashOfSourceAsset(): Buffer {
        return hashOf(assetBytes);
    }

    //
    // The SHA-256 of some bytes, which is what a correct copy of them must match.
    //
    function hashOf(bytes: Buffer): Buffer {
        return createHash("sha256").update(bytes).digest();
    }
});
