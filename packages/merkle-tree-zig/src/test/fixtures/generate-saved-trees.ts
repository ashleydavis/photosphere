//
// Generates the golden fixtures of the byte-level save tests (saved-trees.test.zig).
// Run from the repo root with: bun run packages/merkle-tree-zig/src/test/fixtures/generate-saved-trees.ts
//
// Every expected value is produced by the TypeScript merkle-tree package under Bun, so the Zig tests prove that Zig
// writes byte-identical tree files:
// - saved-trees.bin: every merkle tree in test/dbs loaded and saved again by TypeScript (loadTree + saveTree).
// - buffer-collisions.json: BufferSet and BufferMap iteration order after operations on hashes that share XOR buckets.
// - collision-tree.json and collision-tree.dat: a tree whose content hashes share XOR buckets, saved by TypeScript.
//

import * as fs from "fs";
import * as path from "path";
import { createHash } from "crypto";
import { BufferMap, BufferSet, addItem, buildMerkleTree, createTree, loadTree, saveTree, type IMerkleTree } from "merkle-tree";
import { FileStorage } from "storage";

//
// The directory this script lives in (fixtures are written next to it).
//
const fixturesDir = path.dirname(new URL(import.meta.url).pathname);

//
// The repo's test databases.
//
const testDbsDir = path.resolve(fixturesDir, "../../../../../test/dbs");

//
// Storage for absolute paths.
//
const storage = new FileStorage("");

//
// Throws when a condition does not hold (sanity checks on the TypeScript side).
//
function assert(condition: boolean, message: string): void {
    if (!condition) {
        throw new Error(`Fixture sanity check failed: ${message}`);
    }
}

//
// Returns the type code TypeScript loads a merkle tree file of test/dbs with, or undefined when the file is not a
// merkle tree (sort index trees and the hash cache).
//
function treeTypeCode(relativePath: string): string | undefined {
    if (relativePath.includes("/indexes/") || relativePath.includes("/sort_indexes/") || path.basename(relativePath).startsWith("hash-cache")) {
        return undefined;
    }
    const baseName = path.basename(relativePath);
    if (baseName === "files.dat" || baseName === "tree.dat") {
        return "FTRE";
    }
    if (baseName === "db.dat") {
        return "BDBT";
    }
    return "COLT";
}

//
// Lists every file under a directory (relative paths, sorted).
//
function listFiles(directory: string, relativeDirectory: string): string[] {
    const files: string[] = [];
    for (const entry of fs.readdirSync(path.join(directory, relativeDirectory), { withFileTypes: true })) {
        const relativePath = path.join(relativeDirectory, entry.name);
        if (entry.isDirectory()) {
            files.push(...listFiles(directory, relativePath));
        }
        else {
            files.push(relativePath);
        }
    }
    return files.sort();
}

//
// saved-trees.bin: [u32 count] then for each tree [u32 length][path relative to test/dbs][u32 length][type code]
// [u32 length][the file TypeScript saveTree wrote], all little endian.
//
async function generateSavedTrees(): Promise<void> {
    const parts: Buffer[] = [];
    let count = 0;
    const writeBlock = (data: Buffer) => {
        const length = Buffer.alloc(4);
        length.writeUInt32LE(data.length);
        parts.push(length, data);
    };
    const savedPath = path.join(fixturesDir, "saved-tree.tmp");
    for (const relativePath of listFiles(testDbsDir, "")) {
        if (!relativePath.endsWith(".dat")) {
            continue;
        }
        const typeCode = treeTypeCode(relativePath);
        if (!typeCode) {
            continue;
        }
        const tree = await loadTree(path.join(testDbsDir, relativePath), storage, typeCode);
        assert(tree !== undefined && !tree.dirty, `load ${relativePath}`);
        await saveTree(savedPath, tree!, storage, typeCode);
        writeBlock(Buffer.from(relativePath));
        writeBlock(Buffer.from(typeCode));
        writeBlock(fs.readFileSync(savedPath));
        count++;
    }
    fs.unlinkSync(savedPath);
    const countBuffer = Buffer.alloc(4);
    countBuffer.writeUInt32LE(count);
    fs.writeFileSync(path.join(fixturesDir, "saved-trees.bin"), Buffer.concat([countBuffer, ...parts]));
    console.log(`Wrote ${count} saved trees`);
}

//
// Returns a copy of a hash with the first two 32-bit chunks xored with the same value, so it lands in the same
// BufferSet / BufferMap XOR bucket as the original.
//
function collidingHash(hash: Buffer, value: number): Buffer {
    const copy = Buffer.from(hash);
    copy.writeUInt32BE((copy.readUInt32BE(0) ^ value) >>> 0, 0);
    copy.writeUInt32BE((copy.readUInt32BE(4) ^ value) >>> 0, 4);
    return copy;
}

//
// The SHA-256 of a string.
//
function sha256(text: string): Buffer {
    return createHash("sha256").update(text).digest();
}

//
// An operation on a BufferSet and a BufferMap (an entry of buffer-collisions.json).
//
interface ICollisionStep {
    // "add" (BufferSet.add and BufferMap.set), "delete" (delete on both) or "clear" (clear on both).
    op: string;

    // The hash as hex ("" for clear).
    hash: string;

    // The value passed to BufferMap.set.
    value: number;

    // The hashes BufferSet.values() iterates after the operation (hex).
    setOrder: string[];

    // The "hash:value" entries BufferMap.entries() iterates after the operation.
    mapOrder: string[];

    // What delete returned on the BufferSet and BufferMap ("" for other operations).
    deleted: string;
}

//
// buffer-collisions.json: BufferSet and BufferMap iteration order after adds, updates and deletes of hashes that share
// XOR buckets.
//
function generateBufferCollisions(): void {
    const first = sha256("first");
    const second = sha256("second");
    const third = sha256("third");
    const hashes = {
        a: first,
        b: second,
        aa: collidingHash(first, 0x12345678),
        c: third,
        ab: collidingHash(first, 0x9abcdef0),
        ba: collidingHash(second, 0x0f0f0f0f),
        ca: collidingHash(third, 0xffffffff),
    };
    const operations: [string, keyof typeof hashes | "", number][] = [
        ["add", "a", 1], ["add", "b", 2], ["add", "aa", 3], ["add", "c", 4], ["add", "ab", 5], ["add", "ba", 6],
        ["add", "aa", 7], ["delete", "a", 0], ["add", "a", 8], ["delete", "c", 0], ["delete", "c", 0], ["add", "ca", 9],
        ["add", "c", 10], ["delete", "aa", 0], ["delete", "ab", 0], ["delete", "a", 0], ["add", "ab", 11], ["add", "a", 12],
        ["delete", "b", 0], ["delete", "ba", 0], ["add", "ba", 13], ["add", "b", 14], ["clear", "", 0], ["add", "ca", 15],
        ["add", "c", 16],
    ];
    const set = new BufferSet();
    const map = new BufferMap<number>();
    const steps: ICollisionStep[] = [];
    for (const [op, name, value] of operations) {
        const hash = name === "" ? Buffer.alloc(0) : hashes[name];
        let deleted = "";
        if (op === "add") {
            set.add(hash);
            map.set(hash, value);
        }
        else if (op === "delete") {
            deleted = `${set.delete(hash)} ${map.delete(hash)}`;
        }
        else {
            set.clear();
            map.clear();
        }
        steps.push({
            op,
            hash: hash.toString("hex"),
            value,
            setOrder: Array.from(set.values()).map(buffer => buffer.toString("hex")),
            mapOrder: Array.from(map.entries()).map(([key, entryValue]) => `${key.toString("hex")}:${entryValue}`),
            deleted,
        });
    }
    fs.writeFileSync(path.join(fixturesDir, "buffer-collisions.json"), JSON.stringify({ steps }, null, 1) + "\n");
}

//
// An item of collision-tree.json.
//
interface ICollisionItem {
    // The item name.
    name: string;

    // The item hash as hex.
    hash: string;

    // The item length.
    length: number;

    // The item last modified time in milliseconds.
    lastModified: number;
}

//
// collision-tree.json and collision-tree.dat: a tree whose content hashes share XOR buckets (so the hash table order
// in the file depends on the bucket order), saved by TypeScript.
//
async function generateCollisionTree(): Promise<void> {
    const treeId = "6f0c2b2e-8a53-4b8e-9c7e-2f3d4a5b6c7d";
    const items: ICollisionItem[] = [];
    for (let index = 0; index < 24; index++) {
        const base = sha256(`base-${index % 6}`);
        const hash = index < 6 ? base : collidingHash(base, (0x1000193 * index) >>> 0);
        items.push({ name: `file-${String(23 - index).padStart(2, "0")}`, hash: hash.toString("hex"), length: 1000 + index, lastModified: 1700000000000 + index });
    }
    let tree: IMerkleTree<any> = createTree(treeId);
    for (const item of items) {
        tree = addItem(tree, { name: item.name, hash: Buffer.from(item.hash, "hex"), length: item.length, lastModified: new Date(item.lastModified) });
    }
    tree.merkle = buildMerkleTree(tree.sort);
    tree.dirty = false;
    await saveTree(path.join(fixturesDir, "collision-tree.dat"), tree, storage, "FTRE");
    fs.writeFileSync(path.join(fixturesDir, "collision-tree.json"), JSON.stringify({ treeId, items }, null, 1) + "\n");
}

//
// Generates every fixture of the byte-level save tests.
//
async function main(): Promise<void> {
    await generateSavedTrees();
    generateBufferCollisions();
    await generateCollisionTree();
    console.log(`Wrote fixtures to ${fixturesDir}`);
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
