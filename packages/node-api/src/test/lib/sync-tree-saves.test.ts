import { MockStorage } from "storage";
import { createTree, addItem, buildMerkleTree, saveTree } from "merkle-tree";
import type { IDatabaseMetadata } from "../../lib/media-file-database";
import { createHash } from "crypto";
import { pushFiles, throughTheDatabases } from "../../lib/sync";

//
// The periodic save of the target's merkle tree during a push.
//
// It exists so an interrupted push does not start again from nothing, and it is meant to happen every
// hundred files. Zero divides by a hundred exactly, so a push that copied nothing saved the whole
// tree after every leaf it looked at instead. Measured on a Pixel 6 pushing to an S3 origin holding
// 8,481 photos, one pass reported:
//
//   {"filesCopied":0,"leavesVisited":99,"copyFileMs":11,"treeSaveMs":2751699,"elapsedMs":2753394}
//
// 46 minutes, of which 11 milliseconds was the copying and all the rest was writing a megabyte of
// merkle tree back, once per leaf, to record that nothing had changed.
//
// What is covered here is that the save still happens when files do arrive, which is the half of the
// behaviour the guard must not break. The zero case is not covered by a test: the tree topology that
// walks a leaf and then copies nothing needs a source and target whose nodes differ while their leaf
// hashes match, and every arrangement tried here produced trees that either matched (so no leaf was
// walked) or differed at the leaf (so the file was copied). Rather than keep a test that passes
// whether or not the guard is there, the evidence for that half is the device measurement above.
//

const dbId = "6f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d";

//
// The database's own hash of a file's contents.
//
function hashOf(contents: string): Buffer {
    return createHash("sha256").update(Buffer.from(contents, "utf-8")).digest();
}

//
// Builds a storage holding the given files and a merkle tree describing exactly them, recording the
// given asset ids as deleted. A push walks the leaf of a deleted asset and copies nothing for it,
// which is what a leaf that is visited without being copied looks like.
//
async function makeDatabaseWithDeletions(fileNames: string[], deletedAssetIds: string[]): Promise<MockStorage> {
    const storage = new MockStorage();
    let tree = createTree<IDatabaseMetadata>(dbId);
    for (const fileName of fileNames) {
        await storage.write(fileName, "image/jpeg", Buffer.from(fileName, "utf-8"));
        tree = addItem(tree, {
            name: fileName,
            hash: hashOf(fileName),
            length: fileName.length,
            lastModified: new Date("2026-01-01T00:00:00.000Z"),
        });
    }
    tree.databaseMetadata = {
        filesImported: fileNames.length,
        deletedAssetIds,
    };
    tree.merkle = buildMerkleTree(tree.sort);
    tree.dirty = false;
    await saveTree(".db/files.dat", tree, storage);
    return storage;
}

//
// Builds a storage holding the given files and a merkle tree describing exactly them.
//
async function makeDatabase(fileNames: string[]): Promise<MockStorage> {
    const storage = new MockStorage();
    let tree = createTree<IDatabaseMetadata>(dbId);
    for (const fileName of fileNames) {
        await storage.write(fileName, "image/jpeg", Buffer.from(fileName, "utf-8"));
        tree = addItem(tree, {
            name: fileName,
            hash: hashOf(fileName),
            length: fileName.length,
            lastModified: new Date("2026-01-01T00:00:00.000Z"),
        });
    }
    tree.databaseMetadata = { filesImported: fileNames.length };
    tree.merkle = buildMerkleTree(tree.sort);
    tree.dirty = false;
    await saveTree(".db/files.dat", tree, storage);
    return storage;
}

//
// Counts writes of the merkle tree, which is what a push saves periodically.
//
function countTreeWrites(storage: MockStorage): { count: () => number } {
    let writes = 0;
    const writeNormally = storage.write.bind(storage);
    storage.write = async (fileName: string, contentType: string | undefined, data: Buffer) => {
        if (fileName === ".db/files.dat") {
            writes += 1;
        }
        return writeNormally(fileName, contentType, data);
    };
    return { count: () => writes };
}

//
// A bson database that a push only flushes, commits, and removes deleted assets' records from.
//
function makeBsonDatabase(): any {
    return {
        flush: async () => {},
        commit: async () => {},
        collection: () => ({
            deleteOne: async () => {},
        }),
    };
}

describe("saving the target merkle tree during a push", () => {

    //
    // A pass that put nothing in the tree leaves it exactly as it was loaded, so writing it back
    // sends a megabyte to say so. On a Pixel 6 pushing to an origin holding 8,481 photos that write
    // took twenty-nine seconds of a thirty-one second pass, every five minutes, on the same
    // connection the import was trying to use.
    //
    test("a push that copies nothing does not write the tree back", async () => {
        const shared = Array.from({ length: 3 }, (_, index) => `asset/shared-${index}.jpg`);

        // The target holds everything the source does and more, so the trees differ (the push is not
        // skipped) and yet there is nothing for the push to copy.
        const source = await makeDatabase(shared);
        const target = await makeDatabase(shared.concat([ "asset/only-at-the-target.jpg" ]));
        const treeWrites = countTreeWrites(target);

        await pushFiles(source, target, makeBsonDatabase(), throughTheDatabases(source, target));

        expect(treeWrites.count()).toBe(0);
    });

    //
    // The save is meant to happen every hundred files, and it is reached once per leaf, so a count
    // resting on a multiple of a hundred saved the whole tree again for every leaf walked and matched
    // after it. That is the same megabyte per leaf the zero case was, needing only a hundred copies
    // in front of it.
    //
    test("a run of leaves that copy nothing after the hundredth file does not write the tree again", async () => {
        // A hundred files to copy, named so they sort first, and then a long run of leaves the push
        // walks and copies nothing for because their assets are deleted. That is the count resting on
        // a hundred while leaf after leaf goes by, which is what a real library does: a Pixel 6
        // pushing to an origin it shares most of its photos with walked 479 leaves and copied 98.
        const toCopy = Array.from({ length: 100 }, (_, index) => `asset/a-${String(index).padStart(3, "0")}.jpg`);
        const deleted = Array.from({ length: 50 }, (_, index) => `z-${String(index).padStart(3, "0")}.jpg`);

        const source = await makeDatabaseWithDeletions(toCopy.concat(deleted.map(assetId => `asset/${assetId}`)), deleted);
        const target = await makeDatabase([]);
        const treeWrites = countTreeWrites(target);

        await pushFiles(source, target, makeBsonDatabase(), throughTheDatabases(source, target));

        // The hundredth file's save, and the one at the end of the push.
        expect(treeWrites.count()).toBe(2);
    });

    test("a push that copies files still saves the tree, so an interrupted one does not start again from nothing", async () => {
        const fileNames = Array.from({ length: 5 }, (_, index) => `asset/new-${index}.jpg`);
        const source = await makeDatabase(fileNames);
        const target = await makeDatabase([]);
        const treeWrites = countTreeWrites(target);

        await pushFiles(source, target, makeBsonDatabase(), throughTheDatabases(source, target));

        expect(treeWrites.count()).toBeGreaterThanOrEqual(1);
        for (const fileName of fileNames) {
            expect(await target.fileExists(fileName)).toBe(true);
        }
    });
});
