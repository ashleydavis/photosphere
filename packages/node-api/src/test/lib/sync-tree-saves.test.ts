import { MockStorage } from "storage";
import { createTree, addItem, buildMerkleTree, saveTree } from "merkle-tree";
import type { IDatabaseMetadata } from "../../lib/media-file-database";
import { createHash } from "crypto";
import { pushFiles } from "../../lib/sync";

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
            lastModified: new Date(0),
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
// A bson database that a push only flushes and commits.
//
function makeBsonDatabase(): any {
    return {
        flush: async () => {},
        commit: async () => {},
    };
}

describe("saving the target merkle tree during a push", () => {

    test("a push that copies files still saves the tree, so an interrupted one does not start again from nothing", async () => {
        const fileNames = Array.from({ length: 5 }, (_, index) => `asset/new-${index}.jpg`);
        const source = await makeDatabase(fileNames);
        const target = await makeDatabase([]);
        const treeWrites = countTreeWrites(target);

        await pushFiles(source, target, makeBsonDatabase());

        expect(treeWrites.count()).toBeGreaterThanOrEqual(1);
        for (const fileName of fileNames) {
            expect(await target.fileExists(fileName)).toBe(true);
        }
    });
});
