import { MockStorage } from "storage";
import { createTree, addItem, buildMerkleTree, saveTree } from "merkle-tree";
import { log } from "utils";
import type { IDatabaseMetadata } from "../../lib/media-file-database";
import { createHash } from "crypto";
import { pushFiles } from "../../lib/sync";

//
// How often a push says where its time went.
//
// It is meant to be every twenty files, and zero divides by twenty exactly, so a pass that copied
// nothing said it on every leaf it walked instead. On a Pixel 6 pushing to an origin holding 8,481
// photos that was one line per leaf, thousands of them saying the same thing, and the line that
// mattered (the copy that had failed) was somewhere in the middle of them.
//
// Saying it once at the end covers the pass that copies nothing, which is exactly the pass whose
// time needs explaining: the one that spent forty-six minutes and moved no bytes.
//

const dbId = "5b2c3d4e-6f7a-4b8c-9d0e-1f2a3b4c5d6e";

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

describe("how often a push says where its time went", () => {

    let timingLines: string[];
    let infoSpy: jest.SpyInstance;

    beforeEach(() => {
        timingLines = [];
        infoSpy = jest.spyOn(log, "info").mockImplementation((message: string) => {
            if (message.startsWith("Sync timings:")) {
                timingLines.push(message);
            }
        });
    });

    afterEach(() => {
        infoSpy.mockRestore();
    });

    //
    // The leaves a push walks and does not copy are what the counter sat at zero through, and on a
    // real library they are nearly all of them: an origin holding 8,481 photos was missing a handful.
    //
    test("the leaves a push walks without copying say nothing, and the end says it once", async () => {
        const fileNames = Array.from({ length: 40 }, (_, index) => `asset/same-${index}.jpg`);
        const source = await makeDatabase(fileNames);

        // Every file but the last, so most leaves are walked and matched before anything is copied.
        const target = await makeDatabase(fileNames.slice(0, fileNames.length - 1));

        await pushFiles(source, target, makeBsonDatabase());

        expect(timingLines).toHaveLength(1);
        expect(timingLines[0]).toContain(`"filesCopied":1`);
    });

    //
    // The line is meant to come every twenty files, and it is reached once per leaf, so a count
    // resting on a multiple of twenty said the same thing again for every leaf walked and matched
    // after it. On a Pixel 6 that was five identical lines in a row with the count stuck at sixty.
    //
    test("a run of leaves that copy nothing after the twentieth file says nothing more", async () => {
        // Twenty files to copy, named so they sort first, and then a long run of leaves the push
        // walks and copies nothing for because their assets are deleted. That is the count resting on
        // twenty while leaf after leaf goes by, which is what a real library does: a Pixel 6 pushing
        // to an origin it shares most of its photos with walked 479 leaves and copied 98.
        const toCopy = Array.from({ length: 20 }, (_, index) => `asset/a-${String(index).padStart(3, "0")}.jpg`);
        const deleted = Array.from({ length: 50 }, (_, index) => `z-${String(index).padStart(3, "0")}.jpg`);

        const source = await makeDatabaseWithDeletions(toCopy.concat(deleted.map(assetId => `asset/${assetId}`)), deleted);
        const target = await makeDatabase([]);

        await pushFiles(source, target, makeBsonDatabase());

        // The twentieth file's line, and the one at the end of the push.
        expect(timingLines).toHaveLength(2);
    });

    test("a push that copies files says it while it works and again at the end", async () => {
        const fileNames = Array.from({ length: 45 }, (_, index) => `asset/new-${index}.jpg`);
        const source = await makeDatabase(fileNames);
        const target = await makeDatabase([]);

        await pushFiles(source, target, makeBsonDatabase());

        // Twenty and forty files in, then the one at the end.
        expect(timingLines).toHaveLength(3);
        expect(timingLines[timingLines.length - 1]).toContain(`"filesCopied":45`);
    });
});
