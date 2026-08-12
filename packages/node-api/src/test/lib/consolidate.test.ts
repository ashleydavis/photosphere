import { addItem, createTree, IMerkleTree } from "merkle-tree";
import { planConsolidation } from "../../lib/consolidate";
import { IDatabaseMetadata } from "../../lib/media-file-database";

//
// One file to put in a database's merkle tree.
//
interface ITreeFile {
    // The path in the database, such as "asset/one".
    name: string;

    // The content hash, as hex.
    hash: string;
}

//
// A merkle tree holding the given files.
//
function treeOf(files: ITreeFile[]): IMerkleTree<IDatabaseMetadata> {
    let tree = createTree<IDatabaseMetadata>("test-tree");
    for (const file of files) {
        tree = addItem(tree, {
            name: file.name,
            hash: Buffer.from(file.hash, "hex"),
            length: 100,
            lastModified: new Date("2026-01-01T00:00:00.000Z"),
        });
    }
    return tree;
}

//
// An original with the given asset id and content hash.
//
function original(assetId: string, hash: string): ITreeFile {
    return { name: `asset/${assetId}`, hash };
}

describe("planConsolidation", () => {

    test("everything is absent from an empty remote", () => {
        const local = treeOf([original("one", "aaaa"), original("two", "bbbb")]);
        const remote = treeOf([]);

        const plan = planConsolidation(local, remote);

        expect(plan.absentAssetIds.sort()).toEqual(["one", "two"]);
        expect(plan.presentAssetIds).toEqual([]);
    });

    test("content the remote already holds is not pushed, whatever id it has there", () => {
        // The same photo, given a different asset id in each database. The id says nothing about
        // whether the remote has the content; the hash does.
        const local = treeOf([original("local-id", "aaaa")]);
        const remote = treeOf([original("remote-id", "aaaa")]);

        const plan = planConsolidation(local, remote);

        expect(plan.absentAssetIds).toEqual([]);
        expect(plan.presentAssetIds).toEqual(["local-id"]);
    });

    test("separates what the remote has from what it does not", () => {
        const local = treeOf([
            original("shared", "aaaa"),
            original("only-here", "bbbb"),
            original("also-only-here", "cccc"),
        ]);
        const remote = treeOf([original("their-copy", "aaaa"), original("only-there", "dddd")]);

        const plan = planConsolidation(local, remote);

        expect(plan.absentAssetIds.sort()).toEqual(["also-only-here", "only-here"]);
        expect(plan.presentAssetIds).toEqual(["shared"]);
    });

    test("matches hashes regardless of letter case", () => {
        const local = treeOf([original("one", "AABB")]);
        const remote = treeOf([original("two", "aabb")]);

        expect(planConsolidation(local, remote).presentAssetIds).toEqual(["one"]);
    });

    test("only originals are considered, not thumbnails or display copies", () => {
        const local = treeOf([
            original("one", "aaaa"),
            { name: "thumb/one", hash: "1111" },
            { name: "display/one", hash: "2222" },
        ]);
        const remote = treeOf([]);

        const plan = planConsolidation(local, remote);

        expect(plan.absentAssetIds).toEqual(["one"]);
        expect(plan.presentAssetIds).toEqual([]);
    });

    test("a thumbnail on the remote with a matching hash does not count as the original", () => {
        const local = treeOf([original("one", "aaaa")]);
        const remote = treeOf([{ name: "thumb/other", hash: "aaaa" }]);

        expect(planConsolidation(local, remote).absentAssetIds).toEqual(["one"]);
    });

    test("an empty local database has nothing to push", () => {
        const plan = planConsolidation(treeOf([]), treeOf([original("theirs", "aaaa")]));

        expect(plan.absentAssetIds).toEqual([]);
        expect(plan.presentAssetIds).toEqual([]);
    });

    test("a missing local tree has nothing to push", () => {
        const plan = planConsolidation(undefined, treeOf([original("theirs", "aaaa")]));

        expect(plan.absentAssetIds).toEqual([]);
        expect(plan.presentAssetIds).toEqual([]);
    });

    test("a missing remote tree means everything is absent", () => {
        const plan = planConsolidation(treeOf([original("one", "aaaa")]), undefined);

        expect(plan.absentAssetIds).toEqual(["one"]);
    });
});
