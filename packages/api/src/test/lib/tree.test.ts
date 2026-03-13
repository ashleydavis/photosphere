import * as crypto from "crypto";
import { createTree, addItem, buildMerkleTree, saveTree, iterateLeaves } from "merkle-tree";
import type { HashedItem, SortNode } from "merkle-tree";
import { MockStorage } from "storage";
import { TestUuidGenerator } from "node-utils";
import { buildFilesTree, loadMerkleTree } from "../../lib/tree";
import type { IDatabaseMetadata } from "../../lib/media-file-database";

const FILES_TREE_PATH = ".db/files.dat";
const TREE_ID = "12345678-1234-5678-9abc-123456789abc";

function makeHash(seed: string): Buffer {
    return crypto.createHash("sha256").update(seed, "utf8").digest();
}

function buildMinimalTree(leafNames: string[]): import("merkle-tree").IMerkleTree<IDatabaseMetadata> {
    let tree = createTree<IDatabaseMetadata>(TREE_ID);
    const items: HashedItem[] = leafNames.map(name => ({
        name,
        hash: makeHash(name),
        length: 0,
        lastModified: new Date(),
    }));
    for (const item of items) {
        tree = addItem(tree, item);
    }
    tree.merkle = buildMerkleTree(tree.sort);
    tree.dirty = false;
    tree.databaseMetadata = { filesImported: 0 };
    return tree;
}

describe("buildFilesTree", () => {
    test("builds tree from storage when no existing tree", async () => {
        const storage = new MockStorage();
        await storage.write("asset/f1", "application/octet-stream", Buffer.from("a"));
        await storage.write("display/d1", "application/octet-stream", Buffer.from("b"));
        await storage.write("thumb/t1", "application/octet-stream", Buffer.from("c"));

        const uuidGenerator = new TestUuidGenerator();
        const progressCalls: number[] = [];
        const result = await buildFilesTree(
            storage,
            storage,
            (count) => progressCalls.push(count),
            uuidGenerator
        );

        expect(result.fileCount).toBeGreaterThanOrEqual(3);
        const leafNames = [...iterateLeaves<SortNode>(result.merkleTree.sort)].map(n => n.name).filter(Boolean);
        expect(leafNames).toContain("asset/f1");
        expect(leafNames).toContain("display/d1");
        expect(leafNames).toContain("thumb/t1");
        expect(result.merkleTree.databaseMetadata?.filesImported).toBeGreaterThanOrEqual(1);
        expect(await storage.fileExists(FILES_TREE_PATH)).toBe(true);
        progressCalls.forEach((c, i) => expect(c).toBe(i + 1));
    });

    test("preserves existing tree id when rebuilding", async () => {
        const storage = new MockStorage();
        const existingTree = buildMinimalTree(["asset/old"]);
        await saveTree(FILES_TREE_PATH, existingTree, storage);
        await storage.write("asset/old", "application/octet-stream", Buffer.from("old"));
        await storage.write("asset/new", "application/octet-stream", Buffer.from("new"));

        const uuidGenerator = new TestUuidGenerator();
        const result = await buildFilesTree(storage, storage, () => {}, uuidGenerator);

        expect(result.merkleTree.id).toBe(TREE_ID);
        const leafNames = [...iterateLeaves<SortNode>(result.merkleTree.sort)].map(n => n.name).filter(Boolean);
        expect(leafNames).toContain("asset/old");
        expect(leafNames).toContain("asset/new");
    });

    test("ignores paths under .db/", async () => {
        const storage = new MockStorage();
        await storage.write("asset/f1", "application/octet-stream", Buffer.from("a"));
        await storage.write(".db/config.json", "application/json", Buffer.from("{}"));

        const uuidGenerator = new TestUuidGenerator();
        const result = await buildFilesTree(storage, storage, () => {}, uuidGenerator);

        const leafNames = [...iterateLeaves<SortNode>(result.merkleTree.sort)].map(n => n.name).filter(Boolean);
        expect(leafNames).toContain("asset/f1");
        expect(leafNames).not.toContain(".db/config.json");
    });

    test("returns fileCount 0 and filesImported 0 when storage has no content files", async () => {
        const storage = new MockStorage();

        const uuidGenerator = new TestUuidGenerator();
        const result = await buildFilesTree(storage, storage, () => {}, uuidGenerator);

        expect(result.fileCount).toBe(0);
        expect(result.merkleTree.databaseMetadata?.filesImported).toBe(0);
        expect(await storage.fileExists(FILES_TREE_PATH)).toBe(true);
    });

    test("invokes progressCallback with incrementing count for each file", async () => {
        const storage = new MockStorage();
        await storage.write("asset/a", "application/octet-stream", Buffer.from("a"));
        await storage.write("asset/b", "application/octet-stream", Buffer.from("b"));

        const progressCalls: number[] = [];
        await buildFilesTree(storage, storage, (count) => progressCalls.push(count), new TestUuidGenerator());

        expect(progressCalls.length).toBeGreaterThanOrEqual(2);
        expect(progressCalls[0]).toBe(1);
        expect(progressCalls[progressCalls.length - 1]).toBe(progressCalls.length);
    });

    test("saved tree can be loaded and has correct databaseMetadata", async () => {
        const storage = new MockStorage();
        await storage.write("asset/only", "application/octet-stream", Buffer.from("x"));

        const uuidGenerator = new TestUuidGenerator();
        await buildFilesTree(storage, storage, () => {}, uuidGenerator);

        const loaded = await loadMerkleTree(storage);
        expect(loaded).toBeDefined();
        expect(loaded?.databaseMetadata).toBeDefined();
        expect(loaded?.databaseMetadata?.filesImported).toBeGreaterThanOrEqual(1);
    });
});
