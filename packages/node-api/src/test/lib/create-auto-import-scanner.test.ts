import * as crypto from "crypto";
import * as fsSync from "fs";
import * as path from "path";
import { IAsset } from "api";
import { IStorage } from "storage";
import type { ITaskContext } from "task-queue";
import { IBsonCollection } from "bdb";
import { createTestTempDir } from "node-utils";
import { RandomUuidGenerator } from "utils";
import { createAutoImportScanner } from "../../lib/create-auto-import-scanner";
import { HashCache } from "../../lib/hash-cache";
import { IScannedImportFile } from "../../lib/import-scanner";

//
// What decides whether a photo already in the database is copied and hashed a second time.
//
// This is the whole cost of a run over a library that has already been imported, on every platform:
// a watched folder on the desktop and the CLI, and the device photo library on a phone. An item the
// cache answers for is never opened, so on a phone it is never copied out of the library and never
// read back, and on the desktop it is never read or hashed.
//
// The tests drive a real folder source and a real hash cache, because the question they are asking
// is whether the identity the import writes into the cache is one a later listing produces again.
// Stubbing either side would answer that question by assumption.
//

//
// The asset ids the database is holding against a content hash, so a test can say what the database
// knows without one.
//
let assetIdsByContentHash: Map<string, string>;

//
// A metadata collection that answers the one question the scanner asks it: which assets hold this
// content hash.
//
function makeMetadataCollection(): IBsonCollection<IAsset> {
    return {
        sortIndex: (_fieldName: string, _direction: string) => ({
            findByValue: async (contentHash: string) => {
                const assetId = assetIdsByContentHash.get(contentHash);
                return assetId === undefined ? [] : [{ _id: assetId } as IAsset];
            },
        }),
    } as unknown as IBsonCollection<IAsset>;
}

//
// A task context that never cancels.
//
function makeContext(): ITaskContext {
    return {
        uuidGenerator: new RandomUuidGenerator(),
        isCancelled: () => false,
    } as unknown as ITaskContext;
}

describe("createAutoImportScanner", () => {

    let tempDir: string;
    let watchedDir: string;
    let photoPath: string;
    let hashCache: HashCache;

    beforeEach(async () => {
        assetIdsByContentHash = new Map<string, string>();

        tempDir = createTestTempDir("create-auto-import-scanner");
        watchedDir = path.join(tempDir, "watched");
        fsSync.mkdirSync(watchedDir, { recursive: true });

        photoPath = path.join(watchedDir, "photo.jpg");
        fsSync.writeFileSync(photoPath, "the contents of a photo");

        hashCache = new HashCache(path.join(tempDir, "hash-cache"));
        await hashCache.load();
    });

    //
    // Runs one pass over the watched folder and returns the files it pushed at the import.
    //
    // A file that is pushed is one the run is about to open, read and hash. An empty list is a run
    // that recognised everything it saw and did none of that.
    //
    async function runOnePass(): Promise<IScannedImportFile[]> {
        const scanner = await createAutoImportScanner({
            auto: true,
            sources: [
                {
                    type: "folder",
                    path: watchedDir,
                    recurse: true,
                },
            ],
            storage: {} as IStorage,
            metadataCollection: makeMetadataCollection(),
            localHashCache: hashCache,
            sessionTempDir: tempDir,
            context: makeContext(),
            onProgress: () => { /* nothing listening. */ },
        });

        const pushed: IScannedImportFile[] = [];
        await scanner.scan(
            async result => {
                pushed.push(result);
            },
            () => { /* nothing listening. */ }
        );

        return pushed;
    }

    //
    // What the folder listing reports about the photo, which is what the import records against it.
    //
    function photoIdentity(): { key: string, length: number, lastModified: Date } {
        const stat = fsSync.statSync(photoPath);
        return {
            key: photoPath,
            length: stat.size,
            lastModified: stat.mtime,
        };
    }

    //
    // Records the photo in the cache the way a finished import does: the content hash under the
    // identity the listing reports, and the id the asset was given in the database.
    //
    function recordAsImported(assetId: string): void {
        const identity = photoIdentity();
        hashCache.addSourceHash(identity.key, {
            hash: crypto.createHash("sha256").update("the contents of a photo").digest(),
            length: identity.length,
            lastModified: identity.lastModified,
        });
        hashCache.setAssetId(identity.key, assetId);
    }

    test("a photo nothing is known about is pushed to the import", async () => {
        const pushed = await runOnePass();

        expect(pushed.map(result => result.filePath)).toEqual([photoPath]);
    });

    test("a photo with an asset id recorded against it is never pushed", async () => {
        // Nothing is read at all here: not the file, not the database. This is the state a library
        // that has already been imported is in, and it is why such a run costs almost nothing.
        recordAsImported("asset-1");

        expect(await runOnePass()).toEqual([]);
    });

    test("a photo the cache knows the hash of, but not where it landed, is looked up in the database", async () => {
        // An earlier run hashed it but was stopped before it recorded where it went. The database is
        // asked for that hash, exactly as the import itself would.
        const identity = photoIdentity();
        const contentHash = crypto.createHash("sha256").update("the contents of a photo").digest();
        hashCache.addSourceHash(identity.key, {
            hash: contentHash,
            length: identity.length,
            lastModified: identity.lastModified,
        });
        assetIdsByContentHash.set(contentHash.toString("hex"), "asset-1");

        expect(await runOnePass()).toEqual([]);

        // And the answer is recorded, so the database is not asked a second time.
        expect(hashCache.getHash(identity.key)!.assetId).toBe("asset-1");
    });

    test("a photo the cache has hashed that the database does not hold is pushed", async () => {
        const identity = photoIdentity();
        hashCache.addSourceHash(identity.key, {
            hash: crypto.createHash("sha256").update("the contents of a photo").digest(),
            length: identity.length,
            lastModified: identity.lastModified,
        });

        expect((await runOnePass()).map(result => result.filePath)).toEqual([photoPath]);
    });

    test("a photo whose size no longer matches is pushed, however well known its identity is", async () => {
        recordAsImported("asset-1");
        fsSync.writeFileSync(photoPath, "the contents of a photo, edited and now longer");

        expect((await runOnePass()).map(result => result.filePath)).toEqual([photoPath]);
    });

    test("a photo whose modified time no longer matches is pushed", async () => {
        // The same bytes at a different time. A photo library is free to hand a deleted item's
        // identity to a new one, so an entry is only believed when all three parts agree.
        recordAsImported("asset-1");
        const movedOn = new Date(fsSync.statSync(photoPath).mtime.getTime() + 60000);
        fsSync.utimesSync(photoPath, movedOn, movedOn);

        expect((await runOnePass()).map(result => result.filePath)).toEqual([photoPath]);
    });

    test("what the import records is an identity the next listing produces again", async () => {
        // The whole thing rests on this. The identity written into the cache when a photo is imported
        // has to be the one a later listing of the same source reports, or the lookup can never
        // match and every photo is copied and hashed again on every run.
        const pushed = await runOnePass();

        expect(pushed[0].cacheIdentity).toEqual({
            key: photoIdentity().key,
            length: photoIdentity().length,
            lastModified: photoIdentity().lastModified.getTime(),
        });
    });
});
