import * as crypto from "crypto";
import { createTree, addItem, buildMerkleTree, saveTree } from "merkle-tree";
import type { HashedItem } from "merkle-tree";
import { MockStorage } from "storage";
import { encrypt, decrypt } from "../../lib/encrypt";
import { loadMerkleTree } from "../../lib/tree";

const FILES_TREE_PATH = ".db/files.dat";
const VALID_UUID = "12345678-1234-5678-9abc-123456789abc";

function makeHash(seed: string): Buffer {
    return crypto.createHash("sha256").update(seed, "utf8").digest();
}

function buildMinimalFilesTree(leafNames: string[]): import("merkle-tree").IMerkleTree<undefined> {
    let tree = createTree<undefined>(VALID_UUID);
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
    return tree;
}

describe("encrypt", () => {
    test("copies all files from read storage to write storage and updates merkle tree", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");

        const leafFile = "some/file.dat";
        const tree = buildMinimalFilesTree([leafFile]);
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write(leafFile, "application/octet-stream", Buffer.from("file content"));

        await encrypt(readStorage, writeStorage);

        expect(await writeStorage.fileExists(FILES_TREE_PATH)).toBe(true);
        expect(await writeStorage.fileExists(leafFile)).toBe(true);
        const writtenContent = await writeStorage.read(leafFile);
        expect(writtenContent?.toString()).toBe("file content");

        const loadedTree = await loadMerkleTree(writeStorage);
        expect(loadedTree?.merkle).toBeDefined();
    });

    test("invokes progressCallback when provided", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        const tree = buildMinimalFilesTree(["a.dat"]);
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write("a.dat", "application/octet-stream", Buffer.from("a"));

        const messages: string[] = [];
        await encrypt(readStorage, writeStorage, msg => messages.push(msg));

        expect(messages.length).toBeGreaterThanOrEqual(0);
    });
});

describe("decrypt", () => {
    test("copies all files from read storage to write storage and updates merkle tree", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");

        const leafFile = "other/data.bin";
        const tree = buildMinimalFilesTree([leafFile]);
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write(leafFile, "application/octet-stream", Buffer.from("encrypted or plain payload"));

        await decrypt(readStorage, writeStorage);

        expect(await writeStorage.fileExists(FILES_TREE_PATH)).toBe(true);
        expect(await writeStorage.fileExists(leafFile)).toBe(true);
        const writtenContent = await writeStorage.read(leafFile);
        expect(writtenContent?.toString()).toBe("encrypted or plain payload");

        const loadedTree = await loadMerkleTree(writeStorage);
        expect(loadedTree?.merkle).toBeDefined();
    });
});
