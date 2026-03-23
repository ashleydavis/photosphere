import * as crypto from "crypto";
import { createTree, addItem, buildMerkleTree, saveTree, upsertItem } from "merkle-tree";
import type { HashedItem } from "merkle-tree";
import { iterateLeaves } from "merkle-tree";
import { generateKeyPair, hashPublicKey, MockStorage } from "storage";
import { encrypt, encryptableFiles } from "../../lib/encrypt";
import { loadMerkleTree } from "../../lib/tree";
import { getItemInfo } from "merkle-tree";
import { computeHash } from "../../lib/hash";
import { Readable } from "stream";

const FILES_TREE_PATH = ".db/files.dat";
const VALID_UUID = "12345678-1234-5678-9abc-123456789abc";

const encryptKeyPair = generateKeyPair();

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

async function collectFiles(gen: AsyncIterable<string>): Promise<string[]> {
    const results: string[] = [];
    for await (const fileName of gen) {
        results.push(fileName);
    }
    return results;
}

describe("encryptableFiles", () => {
    test("yields regular files", async () => {
        const storage = new MockStorage("read");
        await storage.write("photo/img.jpg", "image/jpeg", Buffer.from("x"));
        await storage.write(".db/bson/meta", "application/octet-stream", Buffer.from("x"));
        const files = await collectFiles(encryptableFiles(storage));
        expect(files).toContain("photo/img.jpg");
        expect(files).toContain(".db/bson/meta");
    });

    test("excludes .db/files.dat", async () => {
        const storage = new MockStorage("read");
        await storage.write(".db/files.dat", "application/octet-stream", Buffer.from("x"));
        await storage.write("photo/img.jpg", "image/jpeg", Buffer.from("x"));
        const files = await collectFiles(encryptableFiles(storage));
        expect(files).not.toContain(".db/files.dat");
        expect(files).toContain("photo/img.jpg");
    });

    test("excludes .db/encryption.pub", async () => {
        const storage = new MockStorage("read");
        await storage.write(".db/encryption.pub", "application/octet-stream", Buffer.from("x"));
        await storage.write("photo/img.jpg", "image/jpeg", Buffer.from("x"));
        const files = await collectFiles(encryptableFiles(storage));
        expect(files).not.toContain(".db/encryption.pub");
    });

    test("excludes README.md", async () => {
        const storage = new MockStorage("read");
        await storage.write("README.md", "text/markdown", Buffer.from("x"));
        await storage.write("photo/img.jpg", "image/jpeg", Buffer.from("x"));
        const files = await collectFiles(encryptableFiles(storage));
        expect(files).not.toContain("README.md");
    });

    test("yields nothing for empty storage", async () => {
        const storage = new MockStorage("read");
        const files = await collectFiles(encryptableFiles(storage));
        expect(files).toEqual([]);
    });

    test("excludes .db/config.json", async () => {
        const storage = new MockStorage("read");
        await storage.write(".db/config.json", "application/json", Buffer.from("{}"));
        await storage.write("photo/img.jpg", "image/jpeg", Buffer.from("x"));
        const files = await collectFiles(encryptableFiles(storage));
        expect(files).not.toContain(".db/config.json");
        expect(files).toContain("photo/img.jpg");
    });
});

describe("encrypt", () => {
    test("copies all files from read storage to write storage and updates merkle tree", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");

        const leafFile = "some/file.dat";
        const tree = buildMinimalFilesTree([leafFile]);
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write(leafFile, "application/octet-stream", Buffer.from("file content"));

        await encrypt(readStorage, writeStorage, () => {}, encryptKeyPair.publicKey, readStorage);

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
        await encrypt(readStorage, writeStorage, msg => messages.push(msg), encryptKeyPair.publicKey, readStorage);

        expect(messages.some(m => m.includes("saved merkle tree"))).toBe(true);
    });

    test("throws when merkle tree cannot be loaded", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        await readStorage.write("asset/x", "application/octet-stream", Buffer.from("x"));

        await expect(
            encrypt(readStorage, writeStorage, () => {}, encryptKeyPair.publicKey, readStorage)
        ).rejects.toThrow("Failed to load merkle tree from database");
    });

    test("returns correct encrypted count for newly encrypted files", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        // Use empty tree to avoid BSON leaf files being written to storage.
        const tree = buildMinimalFilesTree([]);
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write("a.dat", "application/octet-stream", Buffer.from("a"));
        await readStorage.write("b.dat", "application/octet-stream", Buffer.from("b"));

        const result = await encrypt(readStorage, writeStorage, () => {}, encryptKeyPair.publicKey, readStorage);

        expect(result.encrypted).toBe(2);
        expect(result.skipped).toBe(0);
    });

    test("skips files already encrypted with the same key and returns correct skipped count", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        const publicKeyHash = hashPublicKey(encryptKeyPair.publicKey);
        const fakeHeader = Buffer.concat([
            Buffer.from("PSEN", "ascii"),
            Buffer.alloc(4),
            Buffer.from("A2CB", "ascii"),
            publicKeyHash,
        ]);
        // Use empty tree to avoid BSON leaf files being written to storage.
        const tree = buildMinimalFilesTree([]);
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write("already.dat", "application/octet-stream", fakeHeader);

        const result = await encrypt(readStorage, writeStorage, () => {}, encryptKeyPair.publicKey, readStorage);

        expect(result.skipped).toBe(1);
        expect(result.encrypted).toBe(0);
    });

    test("tree entries for tree-tracked files use logical hash, length, lastModified; tree has no .db/files.dat entry", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        const logicalContent = Buffer.from("logical file content");
        const assetPath = "asset/f1";
        const contentHash = await computeHash(Readable.from(logicalContent));
        let tree = buildMinimalFilesTree([assetPath]);
        tree = upsertItem(tree, {
            name: assetPath,
            hash: contentHash,
            length: logicalContent.length,
            lastModified: new Date(),
        });
        tree.merkle = buildMerkleTree(tree.sort);
        tree.dirty = false;
        await saveTree(FILES_TREE_PATH, tree, readStorage);
        await readStorage.write(assetPath, "application/octet-stream", logicalContent);

        await encrypt(readStorage, writeStorage, () => {}, encryptKeyPair.publicKey, readStorage);

        const loadedTree = await loadMerkleTree(writeStorage);
        expect(loadedTree?.merkle).toBeDefined();
        const leafNames = [...iterateLeaves(loadedTree!.merkle!)].map(n => (n as { name?: string }).name).filter(Boolean);
        expect(leafNames).not.toContain(".db/files.dat");
        const itemInfo = getItemInfo(loadedTree!, assetPath);
        expect(itemInfo).toBeDefined();
        expect(itemInfo!.hash.equals(contentHash)).toBe(true);
        expect(itemInfo!.length).toBe(logicalContent.length);
        expect(itemInfo!.lastModified).toBeInstanceOf(Date);
    });
});
