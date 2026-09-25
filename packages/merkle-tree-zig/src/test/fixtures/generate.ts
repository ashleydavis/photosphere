//
// Generates the golden fixtures used by the merkle-tree-zig unit tests (golden.test.zig).
// Run from the repo root with: bun run packages/merkle-tree-zig/src/test/fixtures/generate.ts
//
// Every expected value is produced by the TypeScript merkle-tree package, so the Zig tests prove parity with it:
// - compare-names.json: localeCompare signs of generated name pairs (compareNames).
// - test-db-trees.json: summaries of every tree file in test/dbs/v2..v6 as TypeScript loads them.
// - scenarios.json: add/upsert/update/delete/prune/build sequences with the results and tree summaries TypeScript
//   produces, and scenario-*.dat, the final trees saved by TypeScript.
//

import * as fs from "fs";
import * as path from "path";
import { serialize } from "bson";
import {
    addItem,
    buildMerkleTree,
    compareNames,
    createTree,
    deleteItem,
    findItemNode,
    findMerkleTreeDifferences,
    getItemInfo,
    loadTree,
    pruneTree,
    saveTree,
    updateItem,
    upsertItem,
    type HashedItem,
    type IMerkleTree,
} from "merkle-tree";
import { FileStorage } from "storage";
import { summarizeTree, type ITreeSummary } from "./summary";

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
// Writes a fixture file relative to the fixtures directory.
//
function writeFixture(relativePath: string, data: string): void {
    fs.writeFileSync(path.join(fixturesDir, relativePath), data);
}

//
// A deterministic pseudo random number generator (mulberry32) so the fixtures are reproducible.
//
function createRandom(seed: number): () => number {
    let state = seed >>> 0;
    return () => {
        state = (state + 0x6D2B79F5) >>> 0;
        let value = state;
        value = Math.imul(value ^ (value >>> 15), value | 1);
        value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
        return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
    };
}

//
// A random integer in [0, max).
//
function randomInt(random: () => number, max: number): number {
    return Math.floor(random() * max);
}

//
// Shuffles an array in place (Fisher-Yates).
//
function shuffle<T>(random: () => number, items: T[]): T[] {
    for (let index = items.length - 1; index > 0; index--) {
        const other = randomInt(random, index + 1);
        const temporary = items[index];
        items[index] = items[other];
        items[other] = temporary;
    }
    return items;
}

//
// A random lowercase hex string.
//
function randomHex(random: () => number, length: number): string {
    let text = "";
    for (let index = 0; index < length; index++) {
        text += "0123456789abcdef"[randomInt(random, 16)];
    }
    return text;
}

//
// A random UUID-shaped string.
//
function randomUuid(random: () => number): string {
    return `${randomHex(random, 8)}-${randomHex(random, 4)}-4${randomHex(random, 3)}-a${randomHex(random, 3)}-${randomHex(random, 12)}`;
}

//
// A random string from an alphabet.
//
function randomString(random: () => number, alphabet: string, maxLength: number): string {
    const length = randomInt(random, maxLength + 1);
    let text = "";
    for (let index = 0; index < length; index++) {
        text += alphabet[randomInt(random, alphabet.length)];
    }
    return text;
}

//
// Every printable ASCII character.
//
const printableAscii = Array.from({ length: 95 }, (_, index) => String.fromCharCode(32 + index)).join("");

//
// compare-names.json: the sign of compareNames for many pairs of ASCII names.
//
function generateCompareNames(): void {
    const random = createRandom(1234);
    const alphabets = [
        printableAscii + "\t\n\x01\x7f",
        "aAbB01-_./ ",
        "0123456789",
        "abcXYZ019",
    ];
    const pairs: [string, string, number][] = [];
    const add = (left: string, right: string) => {
        pairs.push([left, right, Math.sign(compareNames(left, right))]);
    };

    const handPicked: [string, string][] = [
        ["01", "1"], ["a01", "a1"], ["a01b", "a1a"], ["a1a", "a01b"], ["a", "A"], ["ab", "Ab"], ["aB", "Ab"],
        ["a-b", "ab"], ["a b", "ab"], ["a_b", "a-b"], ["x\x00", "x"], ["a", "a\x01"], ["a\t", "a"], ["001", "01"],
        ["9", "10"], ["99999999999999999999999", "100000000000000000000000"], ["a-", "a"], ["-a", "a"],
        ["1a", "1-a"], ["file1", "file10"], ["file2", "file10"], ["file02", "file2"], ["File2", "file2"],
        ["README.md", "asset/1"], ["thumb/x", "display/x"], ["", "a"], ["", ""], ["0", "00"], ["0", ""],
        ["a0", "a"], ["a$", "a0"], ["a~", "a$"], ["x.y", "x/y"], ["x/y", "x-y"],
    ];
    for (const [left, right] of handPicked) {
        add(left, right);
        add(right, left);
    }

    for (let index = 0; index < 4000; index++) {
        const alphabet = alphabets[index % alphabets.length];
        const left = randomString(random, alphabet, 8);
        let right: string;
        if (index % 3 === 0 && left.length > 0) {
            // A near miss: change, insert or remove one character.
            const position = randomInt(random, left.length);
            const character = alphabet[randomInt(random, alphabet.length)];
            const mutation = randomInt(random, 3);
            if (mutation === 0) {
                right = left.slice(0, position) + character + left.slice(position + 1);
            }
            else if (mutation === 1) {
                right = left.slice(0, position) + character + left.slice(position);
            }
            else {
                right = left.slice(0, position) + left.slice(position + 1);
            }
        }
        else {
            right = randomString(random, alphabet, 8);
        }
        add(left, right);
    }

    writeFixture("compare-names.json", JSON.stringify({ pairs }));
}

//
// A tree file in the test databases and the type code its loader uses.
//
interface ITestDbTree {
    //
    // Path relative to test/dbs.
    //
    file: string;

    //
    // The type code passed to loadTree.
    //
    typeCode: string;
}

//
// Every merkle tree file in test/dbs/v2..v6 (the sort index tree.dat files are not merkle trees).
//
const testDbTrees: ITestDbTree[] = [
    { file: "v2/.db/tree.dat", typeCode: "FTRE" },
    { file: "v3/.db/tree.dat", typeCode: "FTRE" },
    { file: "v4/.db/tree.dat", typeCode: "FTRE" },
    { file: "v4/metadata/db.dat", typeCode: "BDBT" },
    { file: "v4/metadata/metadata/collection.dat", typeCode: "COLT" },
    { file: "v4/metadata/metadata/96.dat", typeCode: "COLT" },
    { file: "v5/.db/tree.dat", typeCode: "FTRE" },
    { file: "v5/metadata/db.dat", typeCode: "BDBT" },
    { file: "v5/metadata/metadata/collection.dat", typeCode: "COLT" },
    { file: "v5/metadata/metadata/96.dat", typeCode: "COLT" },
    { file: "v6/.db/files.dat", typeCode: "FTRE" },
    { file: "v6/.db/bson/db.dat", typeCode: "BDBT" },
    { file: "v6/.db/bson/collections/metadata/collection.dat", typeCode: "COLT" },
    { file: "v6/.db/bson/collections/metadata/shards/96.dat", typeCode: "COLT" },
];

//
// test-db-trees.json: how TypeScript loads every tree file in the test databases.
//
async function generateTestDbTrees(): Promise<void> {
    const results: (ITestDbTree & { summary: ITreeSummary })[] = [];
    for (const testDbTree of testDbTrees) {
        const tree = await loadTree(path.join(testDbsDir, testDbTree.file), storage, testDbTree.typeCode);
        if (!tree) {
            throw new Error(`Failed to load ${testDbTree.file}`);
        }
        results.push({ ...testDbTree, summary: summarizeTree(tree) });
    }
    writeFixture("test-db-trees.json", JSON.stringify({ trees: results }, null, 1));
}

//
// An item in an operation.
//
interface IItem {
    //
    // The item name.
    //
    name: string;

    //
    // The item hash as hex.
    //
    hash: string;

    //
    // The item length.
    //
    length: number;

    //
    // The item last modified time in milliseconds.
    //
    lastModified: number;
}

//
// One step of a scenario, replayed by the Zig test.
//
interface IOperation {
    //
    // The operation: add, upsert, update, delete, build, info, find, pruneDiff or checkpoint.
    //
    op: string;

    //
    // The item for add, upsert and update.
    //
    item?: IItem;

    //
    // The name for delete, info and find.
    //
    name?: string;

    //
    // The items of the other tree for pruneDiff.
    //
    others?: IItem[];
}

//
// A scenario: the operations, what each operation returned and the tree at each checkpoint.
//
interface IScenario {
    //
    // The scenario name (the saved tree is scenario-<name>.dat).
    //
    name: string;

    //
    // The tree id.
    //
    treeId: string;

    //
    // The database metadata as BSON hex (null for none).
    //
    metadataBson: string | null;

    //
    // The operations in order.
    //
    operations: IOperation[];

    //
    // What update, info, find and pruneDiff returned, in order.
    //
    results: string[];

    //
    // The tree summary at every checkpoint.
    //
    checkpoints: ITreeSummary[];
}

//
// Converts an item to the TypeScript hashed item.
//
function toHashedItem(item: IItem): HashedItem {
    return {
        name: item.name,
        hash: Buffer.from(item.hash, "hex"),
        length: item.length,
        lastModified: new Date(item.lastModified),
    };
}

//
// Builds scenarios and runs them through the TypeScript implementation.
//
class ScenarioBuilder {
    //
    // The operations added so far.
    //
    operations: IOperation[] = [];

    //
    // The random source.
    //
    random: () => number;

    //
    // The names added (and not deleted) so far.
    //
    names: string[] = [];

    //
    // The latest item added or upserted for each name.
    //
    current = new Map<string, IItem>();

    constructor(seed: number) {
        this.random = createRandom(seed);
    }

    //
    // A random item with the name.
    //
    item(name: string): IItem {
        return {
            name,
            hash: randomHex(this.random, 64),
            length: randomInt(this.random, 10_000_000_000),
            lastModified: 1_600_000_000_000 + randomInt(this.random, 200_000_000_000),
        };
    }

    //
    // Adds an item.
    //
    add(name: string): void {
        const item = this.item(name);
        this.operations.push({ op: "add", item });
        this.current.set(name, item);
        this.names.push(name);
    }

    //
    // Upserts an item.
    //
    upsert(name: string): void {
        const item = this.item(name);
        this.operations.push({ op: "upsert", item });
        this.current.set(name, item);
        if (!this.names.includes(name)) {
            this.names.push(name);
        }
    }

    //
    // Adds a named operation.
    //
    push(operation: IOperation): void {
        this.operations.push(operation);
    }

    //
    // A random name that was added.
    //
    existingName(): string {
        return this.names[randomInt(this.random, this.names.length)];
    }

    //
    // Deletes a name.
    //
    delete(name: string): void {
        this.operations.push({ op: "delete", name });
        this.names = this.names.filter(existing => existing !== name);
    }
}

//
// Runs a scenario with the TypeScript implementation and saves its final tree.
//
async function runScenario(name: string, treeId: string, metadata: any, operations: IOperation[]): Promise<IScenario> {
    let tree: IMerkleTree<any> = createTree(treeId);
    tree.databaseMetadata = metadata;
    const results: string[] = [];
    const checkpoints: ITreeSummary[] = [];

    for (const operation of operations) {
        if (operation.op === "add") {
            tree = addItem(tree, toHashedItem(operation.item!));
        }
        else if (operation.op === "upsert") {
            tree = upsertItem(tree, toHashedItem(operation.item!));
        }
        else if (operation.op === "update") {
            results.push(`update ${updateItem(tree, toHashedItem(operation.item!))}`);
        }
        else if (operation.op === "delete") {
            deleteItem(tree, operation.name!);
        }
        else if (operation.op === "build") {
            tree.merkle = buildMerkleTree(tree.sort);
            tree.dirty = false;
        }
        else if (operation.op === "info") {
            const info = getItemInfo(tree, operation.name!);
            results.push(info ? `info ${info.hash.toString("hex")}|${info.length}|${info.lastModified.getTime()}` : "info none");
        }
        else if (operation.op === "find") {
            const node = findItemNode(tree, operation.name!);
            results.push(node ? `find ${node.name}|${node.size}` : "find none");
        }
        else if (operation.op === "pruneDiff") {
            let other: IMerkleTree<any> = createTree(treeId);
            for (const item of operation.others!) {
                other = addItem(other, toHashedItem(item));
            }
            other.merkle = buildMerkleTree(other.sort);
            const diff = findMerkleTreeDifferences(tree.merkle, other.merkle);
            const onlyInTree2Names = diff.onlyInTree2.map(node => `${node.nodeCount}:${node.hash.toString("hex")}`);
            results.push(`diff ${diff.identical} ${onlyInTree2Names.join(",")}`);
            const prunedFiles = pruneTree(tree, diff.onlyInTree1);
            results.push(`pruned ${prunedFiles.join(",")}`);
        }
        else if (operation.op === "checkpoint") {
            checkpoints.push(summarizeTree(tree));
        }
        else {
            throw new Error(`Unknown operation ${operation.op}`);
        }
    }

    await saveTree(path.join(fixturesDir, `scenario-${name}.dat`), tree, storage, "FTRE");

    return {
        name,
        treeId,
        metadataBson: metadata === undefined ? null : Buffer.from(serialize(metadata)).toString("hex"),
        operations,
        results,
        checkpoints,
    };
}

//
// The "files" scenario: a files tree (asset/display/thumb/README.md) with adds, upserts, updates, deletes and a prune.
//
function filesScenario(): IOperation[] {
    const builder = new ScenarioBuilder(1);
    const assetIds = Array.from({ length: 40 }, () => randomUuid(builder.random));
    const names = ["README.md"];
    for (const assetId of assetIds) {
        names.push(`asset/${assetId}`, `display/${assetId}`, `thumb/${assetId}`);
    }
    for (const name of shuffle(builder.random, names)) {
        builder.add(name);
    }
    builder.push({ op: "checkpoint" });
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    for (let index = 0; index < 10; index++) {
        builder.upsert(builder.existingName());
    }
    for (let index = 0; index < 5; index++) {
        builder.upsert(`asset/${randomUuid(builder.random)}`);
    }
    builder.push({ op: "update", item: builder.item("missing/file") });
    builder.push({ op: "update", item: builder.item(builder.existingName()) });
    builder.push({ op: "info", name: builder.existingName() });
    builder.push({ op: "info", name: "README.md" });
    builder.push({ op: "info", name: "missing/file" });
    builder.push({ op: "find", name: builder.existingName() });
    builder.push({ op: "find", name: "thumb/zzz" });
    builder.push({ op: "checkpoint" });
    for (let index = 0; index < 8; index++) {
        builder.delete(builder.existingName());
    }
    builder.delete("not/in/tree");
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });

    // Prune everything that is not in a tree holding a subset of the names (plus two unknown items).
    const others: IItem[] = [];
    for (const name of builder.names) {
        if (builder.random() < 0.7) {
            others.push(builder.current.get(name)!);
        }
    }
    others.push(builder.item("asset/other-1"), builder.item("asset/other-2"));
    builder.push({ op: "pruneDiff", others });
    builder.push({ op: "checkpoint" });
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    builder.add(`display/${randomUuid(builder.random)}`);
    builder.add("README.md");
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    return builder.operations;
}

//
// The "names" scenario: names that exercise the numeric, punctuation and case ordering of compareNames.
//
function namesScenario(): IOperation[] {
    const builder = new ScenarioBuilder(2);
    const names = [
        "file1", "file10", "file2", "File2", "file02", "a", "A", "_a", "-a", "a-b", "a.b", "a/b", "a b", "z9", "z10",
        "z010", "10", "9", "0", "00", "x1y2", "x01y2", "X1Y2", "README.md", "readme.md", "~", "$", "a$b", "a~b",
    ];
    for (let index = 0; index < 60; index++) {
        names.push(randomString(builder.random, "aAbBzZ0129-_./ ~$", 7) || "empty");
    }
    for (const name of shuffle(builder.random, names)) {
        builder.add(name);
    }
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    for (const name of ["file2", "file02", "a", "A", "z10", "missing"]) {
        builder.push({ op: "find", name });
        builder.push({ op: "info", name });
    }
    for (let index = 0; index < 30; index++) {
        builder.delete(builder.existingName());
    }
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    return builder.operations;
}

//
// The "records" scenario: record ids of a shard tree with adds, upserts, deletes and a prune.
//
function recordsScenario(): IOperation[] {
    const builder = new ScenarioBuilder(3);
    for (let index = 0; index < 150; index++) {
        builder.add(randomUuid(builder.random));
    }
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    for (let index = 0; index < 20; index++) {
        builder.upsert(builder.existingName());
    }
    for (let index = 0; index < 30; index++) {
        builder.delete(builder.existingName());
    }
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    const others = builder.names.filter((_, index) => index % 4 !== 0).map(name => builder.current.get(name)!);
    builder.push({ op: "pruneDiff", others });
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    return builder.operations;
}

//
// The "shards" scenario: a collection tree with shard ids 0..99 as leaves.
//
function shardsScenario(): IOperation[] {
    const builder = new ScenarioBuilder(4);
    const names = Array.from({ length: 100 }, (_, index) => index.toString());
    for (const name of shuffle(builder.random, names)) {
        builder.add(name);
    }
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    return builder.operations;
}

//
// The "empty" scenario: a tree that becomes empty again.
//
function emptyScenario(): IOperation[] {
    const builder = new ScenarioBuilder(5);
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    builder.add("only");
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    builder.delete("only");
    builder.push({ op: "build" });
    builder.push({ op: "checkpoint" });
    return builder.operations;
}

//
// scenarios.json and scenario-*.dat.
//
async function generateScenarios(): Promise<void> {
    const scenarios: IScenario[] = [
        await runScenario("files", "1b2c3d4e-0000-4000-8000-000000000001", { filesImported: 121, isPartial: false, deletedAssetIds: ["x", "y"] }, filesScenario()),
        await runScenario("names", "1b2c3d4e-0000-4000-8000-000000000002", undefined, namesScenario()),
        await runScenario("records", "1b2c3d4e-0000-4000-8000-000000000003", undefined, recordsScenario()),
        await runScenario("shards", "1b2c3d4e-0000-4000-8000-000000000004", undefined, shardsScenario()),
        await runScenario("empty", "1b2c3d4e-0000-4000-8000-000000000005", {}, emptyScenario()),
    ];
    writeFixture("scenarios.json", JSON.stringify({ scenarios }, null, 1));
}

//
// Generates every fixture.
//
async function main(): Promise<void> {
    generateCompareNames();
    await generateTestDbTrees();
    await generateScenarios();
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
