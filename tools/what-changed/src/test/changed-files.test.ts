import { PassedFileHashes } from "../lib/cache-store";
import { diffFileHashes, formatChangedFiles, presentFiles, toPassedFileHashes } from "../lib/changed-files";
import { MISSING_FILE_HASH } from "../lib/file-hash";

test("diffFileHashes returns nothing when the tree matches the baseline", () => {
    const current = new Map([["a.txt", "h1"], ["b.txt", "h2"]]);
    const baseline: PassedFileHashes = { "a.txt": "h1", "b.txt": "h2" };

    expect(diffFileHashes(current, baseline)).toEqual([]);
});

test("diffFileHashes reports a modified file with both hashes", () => {
    const current = new Map([["a.txt", "edited"]]);
    const baseline: PassedFileHashes = { "a.txt": "h1" };

    expect(diffFileHashes(current, baseline)).toEqual([
        { path: "a.txt", kind: "modified", hash: "edited", previousHash: "h1" },
    ]);
});

test("diffFileHashes reports a file absent from the baseline as added", () => {
    const current = new Map([["a.txt", "h1"], ["new.txt", "h9"]]);
    const baseline: PassedFileHashes = { "a.txt": "h1" };

    expect(diffFileHashes(current, baseline)).toEqual([
        { path: "new.txt", kind: "added", hash: "h9", previousHash: "" },
    ]);
});

test("diffFileHashes reports a file absent from the tree as deleted, keeping its old hash", () => {
    const current = new Map([["a.txt", "h1"]]);
    const baseline: PassedFileHashes = { "a.txt": "h1", "gone.txt": "h2" };

    expect(diffFileHashes(current, baseline)).toEqual([
        { path: "gone.txt", kind: "deleted", hash: "", previousHash: "h2" },
    ]);
});

test("diffFileHashes returns every kind at once, sorted by path", () => {
    const current = new Map([["a.txt", "h1"], ["m.txt", "edited"], ["z-new.txt", "h9"]]);
    const baseline: PassedFileHashes = { "a.txt": "h1", "m.txt": "h2", "b-gone.txt": "h3" };

    expect(diffFileHashes(current, baseline).map(change => `${change.kind}:${change.path}`)).toEqual([
        "deleted:b-gone.txt",
        "modified:m.txt",
        "added:z-new.txt",
    ]);
});

test("diffFileHashes treats an empty baseline as every file being added", () => {
    const current = new Map([["a.txt", "h1"], ["b.txt", "h2"]]);

    expect(diffFileHashes(current, {}).map(change => change.kind)).toEqual(["added", "added"]);
});

test("diffFileHashes treats an empty tree as every baseline file being deleted", () => {
    const baseline: PassedFileHashes = { "a.txt": "h1" };

    expect(diffFileHashes(new Map(), baseline)).toEqual([
        { path: "a.txt", kind: "deleted", hash: "", previousHash: "h1" },
    ]);
});

test("diffFileHashes reports a tracked file that is missing from disk as deleted", () => {
    //
    // git lists a tracked file even after it has been deleted from the working tree, and hashing it
    // yields MISSING_FILE_HASH. Without special handling that reads as a modification to the literal
    // text "<missing>" rather than as the deletion it is.
    //
    const current = new Map([["a.txt", "h1"], ["gone.txt", MISSING_FILE_HASH]]);
    const baseline: PassedFileHashes = { "a.txt": "h1", "gone.txt": "h2" };

    expect(diffFileHashes(current, baseline)).toEqual([
        { path: "gone.txt", kind: "deleted", hash: "", previousHash: "h2" },
    ]);
});

test("diffFileHashes reports nothing for a file that was already missing at the baseline", () => {
    const current = new Map([["gone.txt", MISSING_FILE_HASH]]);

    expect(diffFileHashes(current, {})).toEqual([]);
});

test("presentFiles drops the entries that are not on disk", () => {
    const current = new Map([["a.txt", "h1"], ["gone.txt", MISSING_FILE_HASH], ["b.txt", "h2"]]);

    expect(Array.from(presentFiles(current).keys())).toEqual(["a.txt", "b.txt"]);
});

test("presentFiles keeps everything when nothing is missing", () => {
    const current = new Map([["a.txt", "h1"], ["b.txt", "h2"]]);

    expect(presentFiles(current)).toEqual(current);
});

test("toPassedFileHashes leaves out a file that is not on disk", () => {
    const current = new Map([["a.txt", "h1"], ["gone.txt", MISSING_FILE_HASH]]);

    expect(toPassedFileHashes(current)).toEqual({ "a.txt": "h1" });
});

test("toPassedFileHashes turns the hash map into a plain object", () => {
    const current = new Map([["a.txt", "h1"], ["dir/b.txt", "h2"]]);

    expect(toPassedFileHashes(current)).toEqual({ "a.txt": "h1", "dir/b.txt": "h2" });
});

test("toPassedFileHashes returns an empty object for an empty map", () => {
    expect(toPassedFileHashes(new Map())).toEqual({});
});

test("formatChangedFiles marks each kind and shortens the hash to sixteen characters", () => {
    const lines = formatChangedFiles([
        { path: "added.txt", kind: "added", hash: "0123456789abcdef0123456789abcdef", previousHash: "" },
        { path: "changed.txt", kind: "modified", hash: "aaaabbbbccccdddd1111", previousHash: "old" },
        { path: "gone.txt", kind: "deleted", hash: "", previousHash: "eeeeffff00001111zzzz" },
    ]);

    expect(lines).toEqual([
        "  A  0123456789abcdef  added.txt",
        "  M  aaaabbbbccccdddd  changed.txt",
        "  D  eeeeffff00001111  gone.txt",
    ]);
});

test("formatChangedFiles returns an empty list for no changes", () => {
    expect(formatChangedFiles([])).toEqual([]);
});
