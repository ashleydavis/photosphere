import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { loadCache, pruneFileHashes, readJsonObject, saveFileHashes, saveTargetHashes, TargetHashes, writeJsonObject } from "../lib/cache-store";
import { FileHashCache } from "../lib/file-hash";

//
// The directory each test uses as the cache directory's parent.
//
let tempDir: string;

//
// The cache directory under test, deliberately not created up front so the tests exercise the
// create-on-demand path.
//
let cacheDir: string;

beforeEach(async () => {
    tempDir = await mkdtemp(path.join(os.tmpdir(), "what-changed-cache-store-"));
    cacheDir = path.join(tempDir, "cache");
});

afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
});

test("loadCache returns empty structures for a directory that does not exist", async () => {
    const cache = await loadCache(cacheDir);

    expect(cache.fileHashes).toEqual({});
    expect(cache.targetHashes).toEqual({});
});

test("loadCache returns empty structures when either JSON file is corrupt", async () => {
    await mkdir(cacheDir, { recursive: true });
    await writeFile(path.join(cacheDir, "file-hashes.json"), "{not json");
    await writeFile(path.join(cacheDir, "target-hashes.json"), "[1, 2, 3]");

    const cache = await loadCache(cacheDir);

    expect(cache.fileHashes).toEqual({});
    expect(cache.targetHashes).toEqual({});
});

test("saveFileHashes then loadCache round-trips the file hashes, creating the directory", async () => {
    const fileHashes: FileHashCache = {
        "a.txt": { mtimeMs: 123, size: 4, hash: "h1" },
    };

    await saveFileHashes(cacheDir, fileHashes);
    const cache = await loadCache(cacheDir);

    expect(cache.fileHashes).toEqual(fileHashes);
});

test("saveTargetHashes then loadCache round-trips the target hashes", async () => {
    const targetHashes: TargetHashes = {
        compile: { packages: "h1", apps: "h2" },
    };

    await saveTargetHashes(cacheDir, targetHashes);
    const cache = await loadCache(cacheDir);

    expect(cache.targetHashes).toEqual(targetHashes);
});

test("saveTargetHashes leaves no .tmp file behind", async () => {
    await saveTargetHashes(cacheDir, { compile: { packages: "h1" } });

    const entries = await readdir(cacheDir);

    expect(entries).toEqual(["target-hashes.json"]);
});

test("readJsonObject returns the parsed object for a well-formed JSON object", async () => {
    await mkdir(cacheDir, { recursive: true });
    const filePath = path.join(cacheDir, "thing.json");
    await writeFile(filePath, JSON.stringify({ alpha: 1 }));

    expect(await readJsonObject(filePath)).toEqual({ alpha: 1 });
});

test("readJsonObject returns an empty object for a file that does not exist", async () => {
    expect(await readJsonObject(path.join(cacheDir, "absent.json"))).toEqual({});
});

test("readJsonObject returns an empty object for unparseable JSON", async () => {
    await mkdir(cacheDir, { recursive: true });
    const filePath = path.join(cacheDir, "broken.json");
    await writeFile(filePath, "{ not json");

    expect(await readJsonObject(filePath)).toEqual({});
});

test("readJsonObject returns an empty object for JSON that is not a plain object", async () => {
    //
    // An array, a bare number and a literal null all parse but are the wrong shape. Returning them
    // would put a non-object into the cache and break every later lookup.
    //
    await mkdir(cacheDir, { recursive: true });
    const arrayPath = path.join(cacheDir, "array.json");
    const numberPath = path.join(cacheDir, "number.json");
    const nullPath = path.join(cacheDir, "null.json");
    await writeFile(arrayPath, "[1, 2, 3]");
    await writeFile(numberPath, "42");
    await writeFile(nullPath, "null");

    expect(await readJsonObject(arrayPath)).toEqual({});
    expect(await readJsonObject(numberPath)).toEqual({});
    expect(await readJsonObject(nullPath)).toEqual({});
});

test("writeJsonObject creates the directory and writes readable JSON", async () => {
    await writeJsonObject(cacheDir, "thing.json", { alpha: 1 });

    expect(await readJsonObject(path.join(cacheDir, "thing.json"))).toEqual({ alpha: 1 });
});

test("writeJsonObject overwrites an existing file and leaves no .tmp behind", async () => {
    await writeJsonObject(cacheDir, "thing.json", { alpha: 1 });
    await writeJsonObject(cacheDir, "thing.json", { beta: 2 });

    expect(await readJsonObject(path.join(cacheDir, "thing.json"))).toEqual({ beta: 2 });
    expect(await readdir(cacheDir)).toEqual(["thing.json"]);
});

test("pruneFileHashes keeps present paths, drops the rest, and does not mutate the input", async () => {
    const fileHashes: FileHashCache = {
        "a.txt": { mtimeMs: 1, size: 1, hash: "h1" },
        "gone.txt": { mtimeMs: 2, size: 2, hash: "h2" },
    };

    const pruned = pruneFileHashes(fileHashes, ["a.txt", "new.txt"]);

    expect(Object.keys(pruned)).toEqual(["a.txt"]);
    expect(Object.keys(fileHashes).sort()).toEqual(["a.txt", "gone.txt"]);
});
