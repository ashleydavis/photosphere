import * as crypto from "crypto";
import { createTree, addItem, buildMerkleTree, upsertItem, saveTree, getItemInfo } from "merkle-tree";
import type { HashedItem, IMerkleTree } from "merkle-tree";
import { generateKeyPair, hashPublicKey, MockStorage } from "storage";
import { encryptFile } from "../../lib/encrypt";
import { IDatabaseMetadata } from "../../lib/media-file-database";
import { computeHash } from "../../lib/hash";
import { Readable } from "stream";

//
// Path to the merkle tree file within storage.
//
const FILES_TREE_PATH = ".db/files.dat";

//
// Stable UUID used for tree construction in tests.
//
const VALID_UUID = "12345678-1234-5678-9abc-123456789abc";

//
// Key pair and derived hash used across all encryptFile tests.
//
const encryptKeyPair = generateKeyPair();
const publicKeyHash = hashPublicKey(encryptKeyPair.publicKey);

//
// Returns a deterministic SHA-256 hash derived from a string seed.
//
function makeHash(seed: string): Buffer {
    return crypto.createHash("sha256").update(seed, "utf8").digest();
}

//
// Builds a minimal merkle tree containing the given leaf file names.
//
function buildTree(leafNames: string[]): IMerkleTree<IDatabaseMetadata> {
    let tree = createTree<IDatabaseMetadata>(VALID_UUID);
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

describe("encryptFile", () => {
    test("writes file to writeStorage", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        const tree = buildTree(["asset/f1"]);
        const content = Buffer.from("hello");
        await readStorage.write("asset/f1", "application/octet-stream", content);

        await encryptFile("asset/f1", readStorage, writeStorage, readStorage, publicKeyHash, tree);

        expect(await writeStorage.fileExists("asset/f1")).toBe(true);
        const written = await writeStorage.read("asset/f1");
        expect(written?.toString()).toBe("hello");
    });

    test("updates merkle tree entry after writing", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        const content = Buffer.from("update me");
        const contentHash = await computeHash(Readable.from(content));
        let tree = buildTree(["asset/f1"]);
        tree = upsertItem(tree, {
            name: "asset/f1",
            hash: contentHash,
            length: content.length,
            lastModified: new Date(),
        });
        tree.merkle = buildMerkleTree(tree.sort);
        tree.dirty = false;
        await readStorage.write("asset/f1", "application/octet-stream", content);

        await encryptFile("asset/f1", readStorage, writeStorage, readStorage, publicKeyHash, tree);

        const info = getItemInfo(tree, "asset/f1");
        expect(info).toBeDefined();
        expect(info!.hash.equals(contentHash)).toBe(true);
    });

    test("does not update merkle tree when file has no existing tree entry", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        // Tree has no entry for "asset/f1"
        const tree = buildTree([]);
        const content = Buffer.from("no tree entry");
        await readStorage.write("asset/f1", "application/octet-stream", content);

        await encryptFile("asset/f1", readStorage, writeStorage, readStorage, publicKeyHash, tree);

        expect(await writeStorage.fileExists("asset/f1")).toBe(true);
        expect(getItemInfo(tree, "asset/f1")).toBeUndefined();
    });

    test("does not update merkle tree for .db/ files", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        const tree = buildTree([]);
        const content = Buffer.from("db file");
        await readStorage.write(".db/something", "application/octet-stream", content);

        await encryptFile(".db/something", readStorage, writeStorage, readStorage, publicKeyHash, tree);

        expect(await writeStorage.fileExists(".db/something")).toBe(true);
        // Tree should be unmodified (no entry for .db/ files)
        const info = getItemInfo(tree, ".db/something");
        expect(info).toBeUndefined();
    });

    test("throws when source file does not exist", async () => {
        const readStorage = new MockStorage("read");
        const writeStorage = new MockStorage("write");
        const tree = buildTree([]);

        await expect(
            encryptFile("missing/file.dat", readStorage, writeStorage, readStorage, publicKeyHash, tree)
        ).rejects.toThrow("does not exist");
    });
});
