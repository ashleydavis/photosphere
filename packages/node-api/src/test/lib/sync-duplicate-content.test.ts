import { MockStorage } from "storage";
import { createTree, addItem, buildMerkleTree, saveTree, loadTree, getItemInfo } from "merkle-tree";
import type { IDatabaseMetadata } from "../../lib/media-file-database";
import { createHash } from "crypto";
import { pushFiles, throughTheDatabases } from "../../lib/sync";

//
// A push decides what to copy by name, not by content.
//
// It used to decide with the merkle diff, and the merkle diff matches leaves by hash: a file whose
// content the target already held under another name was never offered for copying, so it never
// arrived. A library holds such files whenever a photo has been imported twice, which happens when an
// import stops before its batch is written and the next run imports the same photos again under new
// ids. Measured on a Pixel 6 against an origin holding 15,491 files, 243 files of 101 assets were
// missing at the origin after five passes that had each reported nothing left behind.
//
// The merkle diff counts each hash and matches the source's leaves against that count in the order
// it visits them, so which of two same-content leaves it calls "already there" is the visiting order,
// not the name: when the target holds the second, the first is matched away and the second is offered,
// and the second copies nothing because it is already there.
//

const dbId = "6f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d";

//
// A file to put in a database: its name and its contents.
//
interface IFileToStore {
    // Where the file lives.
    name: string;

    // What it holds.
    contents: string;
}

//
// Builds a storage holding the given files and a merkle tree describing exactly them.
//
async function makeDatabase(files: IFileToStore[]): Promise<MockStorage> {
    const storage = new MockStorage();
    let tree = createTree<IDatabaseMetadata>(dbId);
    for (const file of files) {
        const contents = Buffer.from(file.contents, "utf-8");
        await storage.write(file.name, "image/jpeg", contents);
        tree = addItem(tree, {
            name: file.name,
            hash: createHash("sha256").update(contents).digest(),
            length: contents.length,
            lastModified: new Date("2026-01-01T00:00:00.000Z"),
        });
    }
    tree.databaseMetadata = { filesImported: files.length };
    tree.merkle = buildMerkleTree(tree.sort);
    tree.dirty = false;
    await saveTree(".db/files.dat", tree, storage);
    return storage;
}

//
// A bson database that a push only flushes and commits.
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

describe("pushing a file whose content the target already holds under another name", () => {

    test("the file arrives at the target under its own name", async () => {
        const photo = "the same photo imported twice";
        const source = await makeDatabase([
            {
                name: "asset/first-import",
                contents: photo,
            },
            {
                name: "asset/second-import",
                contents: photo,
            },
        ]);
        const target = await makeDatabase([
            {
                name: "asset/second-import",
                contents: photo,
            },
        ]);

        await pushFiles(source, target, makeBsonDatabase(), throughTheDatabases(source, target));

        expect(await target.fileExists("asset/first-import")).toBe(true);
        const targetTree = await loadTree<IDatabaseMetadata>(".db/files.dat", target);
        expect(getItemInfo(targetTree!, "asset/first-import")).toBeDefined();
    });
});
