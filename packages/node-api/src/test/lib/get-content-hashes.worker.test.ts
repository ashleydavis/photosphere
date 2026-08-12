import type { ITaskContext } from "task-queue";
import { addItem, createTree } from "merkle-tree";

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn().mockResolvedValue({ storage: {}, rawStorage: {} }),
}));

jest.mock("../../lib/tree", () => ({
    loadMerkleTree: jest.fn().mockResolvedValue(undefined),
}));

import { loadMerkleTree } from "../../lib/tree";
import { getContentHashesHandler } from "../../lib/get-content-hashes.worker";

const mockLoadMerkleTree = loadMerkleTree as jest.MockedFunction<typeof loadMerkleTree>;

//
// The handler reads nothing from the context, so an empty one is enough to call it.
//
const emptyContext = {} as ITaskContext;

//
// A merkle tree holding the named files at the given content hashes.
//
function makeTree(entries: { name: string, hash: string }[]): any {
    let tree = createTree<any>("test-tree");
    for (const entry of entries) {
        tree = addItem(tree, {
            name: entry.name,
            hash: Buffer.from(entry.hash, "hex"),
            length: 100,
            lastModified: new Date("2026-01-01T00:00:00.000Z"),
        });
    }
    return tree;
}

describe("getContentHashesHandler", () => {

    beforeEach(() => {
        mockLoadMerkleTree.mockReset();
    });

    test("a database with no tree yet holds no content hashes", async () => {
        mockLoadMerkleTree.mockResolvedValue(undefined);

        const result = await getContentHashesHandler({ databasePath: "db" }, emptyContext);

        expect(result.contentHashes).toEqual([]);
    });

    test("the hashes of the assets the database holds come back, in lower-case hex", async () => {
        mockLoadMerkleTree.mockResolvedValue(makeTree([
            { name: "asset/one", hash: "AABBCC" },
            { name: "asset/two", hash: "DDEEFF" },
        ]));

        const result = await getContentHashesHandler({ databasePath: "db" }, emptyContext);

        expect(result.contentHashes.sort()).toEqual(["aabbcc", "ddeeff"]);
    });

    test("files that are not assets are left out, so a thumbnail cannot confirm an original", async () => {
        mockLoadMerkleTree.mockResolvedValue(makeTree([
            { name: "asset/one", hash: "aabbcc" },
            { name: "thumb/one", hash: "112233" },
            { name: "display/one", hash: "445566" },
        ]));

        const result = await getContentHashesHandler({ databasePath: "db" }, emptyContext);

        expect(result.contentHashes).toEqual(["aabbcc"]);
    });

    test("a missing database path is refused rather than read as an empty database", async () => {
        await expect(getContentHashesHandler({ databasePath: "" }, emptyContext))
            .rejects.toThrow("databasePath is required");
    });
});
