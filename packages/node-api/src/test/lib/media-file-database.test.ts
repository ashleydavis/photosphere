import { createTree, addItem, buildMerkleTree, IMerkleTree } from "merkle-tree";
import { MockStorage } from "storage";
import { getDatabaseSummary, IDatabaseMetadata } from "../../lib/media-file-database";
import { saveMerkleTree } from "../../lib/tree";

const VALID_UUID = "12345678-1234-5678-9abc-123456789abc";

//
// Builds a one-file database in a mock storage, with the database metadata under test written into
// its files merkle tree, and returns the storage ready for getDatabaseSummary to read.
//
async function buildDatabase(databaseMetadata: IDatabaseMetadata | undefined): Promise<MockStorage> {
    const storage = new MockStorage();
    let tree: IMerkleTree<IDatabaseMetadata> = createTree<IDatabaseMetadata>(VALID_UUID);
    tree = addItem(tree, {
        name: "thumb/photo.jpg",
        hash: Buffer.alloc(32, 1),
        length: 100,
        lastModified: new Date(0),
    });
    tree.merkle = buildMerkleTree(tree.sort);
    tree.dirty = false;
    tree.databaseMetadata = databaseMetadata;
    await saveMerkleTree(tree, storage);
    return storage;
}

describe("getDatabaseSummary", () => {
    test("reports partial mode when the tree says the database is partial", async () => {
        const storage = await buildDatabase({ filesImported: 1, isPartial: true });

        const summary = await getDatabaseSummary(storage);

        expect(summary.mode).toBe("partial");
    });

    test("reports full mode when the tree says the database is not partial", async () => {
        const storage = await buildDatabase({ filesImported: 1, isPartial: false });

        const summary = await getDatabaseSummary(storage);

        expect(summary.mode).toBe("full");
    });

    test("reports full mode when the tree has no database metadata", async () => {
        const storage = await buildDatabase(undefined);

        const summary = await getDatabaseSummary(storage);

        expect(summary.mode).toBe("full");
    });
});
