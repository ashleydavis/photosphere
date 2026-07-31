import { createHash } from "node:crypto";
import { mkdtemp, rm, utimes, writeFile } from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { FileHashCache, hashFile, hashFiles, MISSING_FILE_HASH } from "../lib/file-hash";

//
// The directory each test writes its throwaway files into.
//
let tempDir: string;

//
// Returns the SHA-256 hex digest of a string, so the tests state the expected hash independently of
// the code under test.
//
function sha256Of(content: string): string {
    return createHash("sha256").update(Buffer.from(content)).digest("hex");
}

beforeEach(async () => {
    tempDir = await mkdtemp(path.join(os.tmpdir(), "what-changed-file-hash-"));
});

afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
});

test("hashFile returns the content hash and populates the cache on a cold cache", async () => {
    await writeFile(path.join(tempDir, "a.txt"), "hello");
    const cache: FileHashCache = {};

    const hash = await hashFile(tempDir, "a.txt", cache);

    expect(hash).toBe(sha256Of("hello"));
    expect(cache["a.txt"].hash).toBe(sha256Of("hello"));
    expect(cache["a.txt"].size).toBe(5);
    expect(cache["a.txt"].mtimeMs).toBeGreaterThan(0);
});

test("hashFile returns the cached hash without reading the file when mtime and size match", async () => {
    const filePath = path.join(tempDir, "a.txt");
    await writeFile(filePath, "hello");
    const cache: FileHashCache = {};
    await hashFile(tempDir, "a.txt", cache);

    //
    // A deliberately wrong hash. Getting it back proves the file was not read again.
    //
    cache["a.txt"].hash = "not-a-real-hash";

    const hash = await hashFile(tempDir, "a.txt", cache);

    expect(hash).toBe("not-a-real-hash");
});

test("hashFile re-reads the file when the cached size differs", async () => {
    await writeFile(path.join(tempDir, "a.txt"), "hello");
    const cache: FileHashCache = {};
    await hashFile(tempDir, "a.txt", cache);
    cache["a.txt"].hash = "not-a-real-hash";
    cache["a.txt"].size = 999;

    const hash = await hashFile(tempDir, "a.txt", cache);

    expect(hash).toBe(sha256Of("hello"));
    expect(cache["a.txt"].hash).toBe(sha256Of("hello"));
    expect(cache["a.txt"].size).toBe(5);
});

test("hashFile re-reads the file when the mtime differs but the size does not", async () => {
    const filePath = path.join(tempDir, "a.txt");
    await writeFile(filePath, "hello");
    const cache: FileHashCache = {};
    await hashFile(tempDir, "a.txt", cache);
    cache["a.txt"].hash = "not-a-real-hash";

    //
    // Same length, different content, and the modification time is pushed forward so the change is
    // visible even on a filesystem with a coarse timestamp.
    //
    await writeFile(filePath, "world");
    const laterTime = new Date(Date.now() + 60000);
    await utimes(filePath, laterTime, laterTime);

    const hash = await hashFile(tempDir, "a.txt", cache);

    expect(hash).toBe(sha256Of("world"));
    expect(cache["a.txt"].hash).toBe(sha256Of("world"));
});

test("hashFile returns MISSING_FILE_HASH and leaves the cache untouched for a path that does not exist", async () => {
    const cache: FileHashCache = {};

    const hash = await hashFile(tempDir, "gone.txt", cache);

    expect(hash).toBe(MISSING_FILE_HASH);
    expect(Object.keys(cache)).toEqual([]);
});

test("hashFile propagates a stat error that is not ENOENT", async () => {
    //
    // A path whose parent is a regular file stats as ENOTDIR, not ENOENT. That is a real problem with
    // the caller's path list, not a deleted file, so it must surface rather than be swallowed as
    // MISSING_FILE_HASH.
    //
    await writeFile(path.join(tempDir, "a.txt"), "hello");
    const cache: FileHashCache = {};

    await expect(hashFile(tempDir, "a.txt/below.txt", cache)).rejects.toThrow(/ENOTDIR/);
    expect(Object.keys(cache)).toEqual([]);
});

test("hashFiles returns a map covering every requested path and shares one cache", async () => {
    await writeFile(path.join(tempDir, "a.txt"), "one");
    await writeFile(path.join(tempDir, "b.txt"), "two");
    const cache: FileHashCache = {};

    const hashes = await hashFiles(tempDir, ["a.txt", "b.txt", "missing.txt"], cache);

    expect(hashes.get("a.txt")).toBe(sha256Of("one"));
    expect(hashes.get("b.txt")).toBe(sha256Of("two"));
    expect(hashes.get("missing.txt")).toBe(MISSING_FILE_HASH);
    expect(Object.keys(cache).sort()).toEqual(["a.txt", "b.txt"]);
});
