import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { PassedFileHashes } from "../src/lib/cache-store";
import { diffFileHashes, toPassedFileHashes } from "../src/lib/changed-files";
import { FileHashCache, hashFiles } from "../src/lib/file-hash";
import { buildTree, hashForPath } from "../src/lib/merkle";

//
// The tree sizes each benchmark is run at. The largest is well past any real repository, so the shape
// of the curve is visible rather than just one number.
//
const TREE_SIZES = [100, 1000, 5000, 20000];

//
// Bytes written into each generated file. Small on purpose: this measures the tool's own cost, and a
// large payload would only measure the filesystem's read throughput.
//
const FILE_SIZE_BYTES = 512;

//
// The slowest a single warm check is allowed to be, in milliseconds per file. A warm check is one
// `stat` and a map lookup, so anything approaching a millisecond per file means something is wrong.
//
const WARM_BUDGET_MS_PER_FILE = 0.05;

//
// One measured result, ready to be printed as a row.
//
interface BenchmarkResult {
    //
    // What was measured.
    //
    name: string;

    //
    // How many files the tree held.
    //
    fileCount: number;

    //
    // How long the measured work took, in milliseconds.
    //
    milliseconds: number;
}

//
// Every result gathered so far, printed as one table at the end.
//
const results: BenchmarkResult[] = [];

//
// Runs a function and returns its result alongside how long it took in milliseconds.
//
async function measure<T>(work: () => Promise<T>): Promise<[T, number]> {
    const start = process.hrtime.bigint();
    const result = await work();
    const end = process.hrtime.bigint();
    return [result, Number(end - start) / 1e6];
}

//
// Records a measurement and prints it as it happens, so a long run shows progress.
//
function record(name: string, fileCount: number, milliseconds: number): void {
    results.push({ name, fileCount, milliseconds });
    console.log(`  ${name} at ${fileCount} files: ${milliseconds.toFixed(1)}ms`);
}

//
// Writes a tree of files spread across directories, mimicking the shape of a real project rather than
// one flat directory, and returns their relative paths.
//
async function buildFileTree(rootDir: string, fileCount: number): Promise<string[]> {
    const filesPerDirectory = 50;
    const directoryCount = Math.ceil(fileCount / filesPerDirectory);
    const relativePaths: string[] = [];
    const content = "x".repeat(FILE_SIZE_BYTES);

    for (let directoryIndex = 0; directoryIndex < directoryCount; directoryIndex++) {
        const directory = path.join("packages", `package-${directoryIndex}`, "src");
        await mkdir(path.join(rootDir, directory), { recursive: true });
        for (let fileIndex = 0; fileIndex < filesPerDirectory && relativePaths.length < fileCount; fileIndex++) {
            const relativePath = `${directory}/file-${fileIndex}.ts`;
            await writeFile(path.join(rootDir, relativePath), `${content}${relativePath}`);
            relativePaths.push(relativePath);
        }
    }
    return relativePaths;
}

//
// Measures the four stages that decide how long a check takes: hashing with a cold cache, hashing with
// a warm one, building the hash tree, and looking a watched path up in it.
//
async function benchmarkSize(fileCount: number): Promise<boolean> {
    const rootDir = await mkdtemp(path.join(os.tmpdir(), "what-changed-perf-"));
    let withinBudget = true;

    try {
        const relativePaths = await buildFileTree(rootDir, fileCount);

        const coldCache: FileHashCache = {};
        const [, coldMs] = await measure(() => hashFiles(rootDir, relativePaths, coldCache));
        record("hash (cold, reads every file)", fileCount, coldMs);

        const [fileHashes, warmMs] = await measure(() => hashFiles(rootDir, relativePaths, coldCache));
        record("hash (warm, stat only)", fileCount, warmMs);

        const perFileMs = warmMs / fileCount;
        if (perFileMs > WARM_BUDGET_MS_PER_FILE) {
            console.log(`  BUDGET EXCEEDED: warm hashing took ${perFileMs.toFixed(4)}ms per file, budget is ${WARM_BUDGET_MS_PER_FILE}ms`);
            withinBudget = false;
        }

        const [tree, treeMs] = await measure(async () => buildTree(fileHashes));
        record("build hash tree", fileCount, treeMs);

        //
        // One lookup per directory, which is what a config with many targets costs.
        //
        const watchedPaths = Array.from(new Set(relativePaths.map(relativePath => relativePath.split("/").slice(0, 2).join("/"))));
        const [, lookupMs] = await measure(async () => {
            for (const watchedPath of watchedPaths) {
                hashForPath(tree, watchedPath);
            }
        });
        record("lookup every watched path", fileCount, lookupMs);

        const baseline: PassedFileHashes = toPassedFileHashes(fileHashes);
        const [, diffUnchangedMs] = await measure(async () => diffFileHashes(fileHashes, baseline));
        record("diff files (nothing changed)", fileCount, diffUnchangedMs);

        const oneChanged = new Map(fileHashes);
        oneChanged.set(relativePaths[0], "changed");
        const [, diffChangedMs] = await measure(async () => diffFileHashes(oneChanged, baseline));
        record("diff files (one changed)", fileCount, diffChangedMs);

        return withinBudget;
    }
    finally {
        await rm(rootDir, { recursive: true, force: true });
    }
}

//
// Prints every measurement as one markdown table, so the numbers can be pasted straight into the docs.
//
function printTable(): void {
    const names = Array.from(new Set(results.map(result => result.name)));
    const sizes = Array.from(new Set(results.map(result => result.fileCount))).sort((left, right) => left - right);

    console.log("");
    console.log(`| Stage | ${sizes.map(size => `${size} files`).join(" | ")} |`);
    console.log(`| --- | ${sizes.map(() => "---").join(" | ")} |`);
    for (const name of names) {
        const cells = sizes.map(size => {
            const match = results.find(result => result.name === name && result.fileCount === size);
            return match === undefined ? "" : `${match.milliseconds.toFixed(1)}ms`;
        });
        console.log(`| ${name} | ${cells.join(" | ")} |`);
    }

    console.log("");
    console.log(`| Stage | ${sizes.map(size => `${size} files`).join(" | ")} |`);
    console.log(`| --- | ${sizes.map(() => "---").join(" | ")} |`);
    for (const name of names) {
        const cells = sizes.map(size => {
            const match = results.find(result => result.name === name && result.fileCount === size);
            return match === undefined ? "" : `${(match.milliseconds / size * 1000).toFixed(2)}us`;
        });
        console.log(`| ${name} (per file) | ${cells.join(" | ")} |`);
    }
}

//
// Runs every benchmark at every size and exits non-zero if any of them blew its budget.
//
async function main(): Promise<void> {
    console.log("what-changed performance benchmarks");
    console.log(`File size: ${FILE_SIZE_BYTES} bytes. Warm budget: ${WARM_BUDGET_MS_PER_FILE}ms per file.`);
    console.log("");

    let allWithinBudget = true;
    for (const fileCount of TREE_SIZES) {
        console.log(`${fileCount} files:`);
        const withinBudget = await benchmarkSize(fileCount);
        allWithinBudget = allWithinBudget && withinBudget;
        console.log("");
    }

    printTable();

    console.log("");
    if (!allWithinBudget) {
        console.log("FAIL: at least one stage exceeded its budget.");
        process.exit(1);
    }
    console.log("PASS: every stage within budget.");
}

main();
