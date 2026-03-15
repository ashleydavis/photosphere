import * as crypto from "crypto";
import { createTree, addItem, buildMerkleTree, saveTree, upsertItem } from "merkle-tree";
import type { HashedItem } from "merkle-tree";
import { iterateLeaves } from "merkle-tree";
import { MockStorage } from "storage";
import { decrypt } from "../../lib/decrypt";
import { loadMerkleTree } from "../../lib/tree";
import { getItemInfo } from "merkle-tree";
import { computeHash } from "../../lib/hash";
import { Readable } from "stream";

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

describe("decrypt", () => {
    test("copies all files from read storage to write storage and updates merkle tree", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");

        const leafFile = "other/data.bin";
        const tree = buildMinimalFilesTree([leafFile]);
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write(leafFile, "application/octet-stream", Buffer.from("encrypted or plain payload"));

        await decrypt(readStorage, writeStorage, undefined, readStorage);

        expect(await writeStorage.fileExists(FILES_TREE_PATH)).toBe(true);
        expect(await writeStorage.fileExists(leafFile)).toBe(true);
        const writtenContent = await writeStorage.read(leafFile);
        expect(writtenContent?.toString()).toBe("encrypted or plain payload");

        const loadedTree = await loadMerkleTree(writeStorage);
        expect(loadedTree?.merkle).toBeDefined();
    });

    test("after decrypt, tree entries use logical hash/length and tree has no .db/files.dat entry", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        const logicalContent = Buffer.from("decrypted payload");
        const displayPath = "display/d1";
        const contentHash = await computeHash(Readable.from(logicalContent));
        let tree = buildMinimalFilesTree([displayPath]);
        tree = upsertItem(tree, {
            name: displayPath,
            hash: contentHash,
            length: logicalContent.length,
            lastModified: new Date(),
        });
        tree.merkle = buildMerkleTree(tree.sort);
        tree.dirty = false;
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write(displayPath, "application/octet-stream", logicalContent);

        await decrypt(readStorage, writeStorage, undefined, readStorage);

        const loadedTree = await loadMerkleTree(writeStorage);
        expect(loadedTree?.merkle).toBeDefined();
        const leafNames = [...iterateLeaves(loadedTree!.merkle!)].map(n => (n as { name?: string }).name).filter(Boolean);
        expect(leafNames).not.toContain(".db/files.dat");
        const itemInfo = getItemInfo(loadedTree!, displayPath);
        expect(itemInfo).toBeDefined();
        expect(itemInfo!.hash.equals(contentHash)).toBe(true);
        expect(itemInfo!.length).toBe(logicalContent.length);
    });

    test("invokes progressCallback when provided", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        const tree = buildMinimalFilesTree(["a.dat"]);
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write("a.dat", "application/octet-stream", Buffer.from("a"));

        const messages: string[] = [];
        await decrypt(readStorage, writeStorage, msg => messages.push(msg), readStorage);

        expect(messages.some(m => m.includes("saved merkle tree"))).toBe(true);
    });

    test("when readStorage === writeStorage and file is plain, skips write but updates tree", async () => {
        const storage = new MockStorage("same");
        const leafFile = "asset/f1";
        const tree = buildMinimalFilesTree([leafFile]);
        await saveTree(FILES_TREE_PATH, tree, storage);
        const content = Buffer.from("plain content");
        await storage.write(leafFile, "application/octet-stream", content);

        await decrypt(storage, storage, undefined, storage);

        const readBack = await storage.read(leafFile);
        expect(readBack?.toString()).toBe("plain content");
        const loadedTree = await loadMerkleTree(storage);
        expect(loadedTree?.merkle).toBeDefined();
    });

    test("throws when merkle tree cannot be loaded", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        await readStorage.write("asset/x", "application/octet-stream", Buffer.from("x"));
        await expect(decrypt(readStorage, writeStorage, undefined, readStorage)).rejects.toThrow(
            "Failed to load merkle tree"
        );
    });
});
