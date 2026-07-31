import { mkdtemp, rm } from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { filterIgnoredFiles, isIgnoredFile, listRepoFiles, parseGitFileList, runGitLsFiles } from "../lib/list-files";

//
// This package's own directory, which is inside a real git repository. The tests that need a
// repository read from this one and never write to it: nothing here creates, stages or commits
// anything, in any repository.
//
const packageDir = path.resolve(__dirname, "..", "..");

//
// A directory that is not inside any git repository, for the failure paths.
//
let outsideRepoDir: string;

beforeEach(async () => {
    outsideRepoDir = await mkdtemp(path.join(os.tmpdir(), "what-changed-list-files-"));
});

afterEach(async () => {
    await rm(outsideRepoDir, { recursive: true, force: true });
});

test("listRepoFiles returns this package's tracked files", async () => {
    const files = await listRepoFiles(packageDir);

    expect(files.length).toBeGreaterThan(0);
    expect(files).toContain("package.json");
    expect(files).toContain("src/lib/list-files.ts");
});

test("listRepoFiles returns paths sorted and free of duplicates", async () => {
    const files = await listRepoFiles(packageDir);

    expect(files).toEqual([...files].sort());
    expect(new Set(files).size).toBe(files.length);
});

test("listRepoFiles excludes paths matched by .gitignore", async () => {
    //
    // "coverage" and "tmp" are both ignored, and both are created by running the test and smoke
    // suites, so at least one of them usually exists on disk while these tests run.
    //
    const files = await listRepoFiles(packageDir);

    expect(files.some(file => file.startsWith("coverage/"))).toBe(false);
    expect(files.some(file => file.startsWith("tmp/"))).toBe(false);
    expect(files.some(file => file.includes("node_modules/"))).toBe(false);
});

test("listRepoFiles returns paths relative to the directory it was given", async () => {
    const files = await listRepoFiles(packageDir);

    expect(files.every(file => !file.startsWith("/"))).toBe(true);
    expect(files.every(file => !file.startsWith("tools/"))).toBe(true);
});

test("listRepoFiles rejects with an error mentioning git outside a git repository", async () => {
    await expect(listRepoFiles(outsideRepoDir)).rejects.toThrow(/git ls-files failed/);
});

test("parseGitFileList splits NUL-separated output and drops the trailing empty entry", () => {
    //
    // Exactly what `git ls-files -z` emits: every path NUL-terminated, so the split leaves a final
    // empty string that must not become a path.
    //
    expect(parseGitFileList("a.txt\0sub/b.txt\0")).toEqual(["a.txt", "sub/b.txt"]);
});

test("parseGitFileList returns an empty list for empty output", () => {
    expect(parseGitFileList("")).toEqual([]);
    expect(parseGitFileList("\0")).toEqual([]);
});

test("parseGitFileList sorts and de-duplicates", () => {
    expect(parseGitFileList("z.txt\0a.txt\0z.txt\0m/c.txt\0")).toEqual(["a.txt", "m/c.txt", "z.txt"]);
});

test("parseGitFileList keeps paths containing spaces, quotes and newlines intact", () => {
    //
    // The -z form is used precisely so these survive. Splitting on anything but NUL would break them,
    // and creating such files on disk is not portable, so the parser is tested against canned bytes.
    //
    const stdout = "with space.txt\0with\"quote.txt\0with\nnewline.txt\0";

    //
    // Sorted by code unit, so the newline (0x0A) comes before the space (0x20).
    //
    expect(parseGitFileList(stdout)).toEqual(["with\nnewline.txt", "with space.txt", "with\"quote.txt"]);
});

test("runGitLsFiles resolves with raw NUL-separated stdout", async () => {
    const stdout = await runGitLsFiles(packageDir);

    expect(stdout).toContain("package.json\0");
    expect(stdout.endsWith("\0")).toBe(true);
});

test("runGitLsFiles rejects naming the directory and the exit code on a non-zero exit", async () => {
    //
    // Not a repository, so git exits 128.
    //
    await expect(runGitLsFiles(outsideRepoDir)).rejects.toThrow(new RegExp(`git ls-files failed in "${outsideRepoDir}" with exit code 128`));
});

test("runGitLsFiles rejects with the spawn error when git never ran at all", async () => {
    //
    // A working directory that does not exist fails at spawn time, before git can write anything to
    // stderr. That is the case where the message has to fall back to the spawn error itself, so this
    // asserts on ENOENT rather than merely on "something failed".
    //
    const missingDir = path.join(outsideRepoDir, "no-such-directory");

    await expect(runGitLsFiles(missingDir)).rejects.toThrow(/git ls-files failed in .* with exit code ENOENT: .*ENOENT/);
});

test("isIgnoredFile matches a listed extension and nothing else", () => {
    expect(isIgnoredFile("docs/readme.md", [".md"])).toBe(true);
    expect(isIgnoredFile("src/index.ts", [".md"])).toBe(false);
});

test("isIgnoredFile matches case-insensitively", () => {
    expect(isIgnoredFile("docs/README.MD", [".md"])).toBe(true);
    expect(isIgnoredFile("docs/readme.md", [".MD"])).toBe(true);
});

test("isIgnoredFile matches any of several extensions", () => {
    const ignored = [".md", ".txt", ".log"];

    expect(isIgnoredFile("a.md", ignored)).toBe(true);
    expect(isIgnoredFile("a.txt", ignored)).toBe(true);
    expect(isIgnoredFile("a.log", ignored)).toBe(true);
    expect(isIgnoredFile("a.ts", ignored)).toBe(false);
});

test("isIgnoredFile keeps everything when no extension is listed", () => {
    expect(isIgnoredFile("docs/readme.md", [])).toBe(false);
});

test("isIgnoredFile does not match an extension appearing mid-path", () => {
    //
    // A directory called "notes.md" holding a .ts file must not be dropped: only the file's own
    // extension decides.
    //
    expect(isIgnoredFile("notes.md/index.ts", [".md"])).toBe(false);
});

test("filterIgnoredFiles removes only the listed extensions and keeps the order", () => {
    const paths = ["a.md", "b.ts", "c.txt", "d.tsx"];

    expect(filterIgnoredFiles(paths, [".md", ".txt"])).toEqual(["b.ts", "d.tsx"]);
});

test("filterIgnoredFiles returns the list untouched when nothing is ignored", () => {
    const paths = ["a.md", "b.ts"];

    expect(filterIgnoredFiles(paths, [])).toBe(paths);
});

test("filterIgnoredFiles can remove every file", () => {
    expect(filterIgnoredFiles(["a.md", "b.md"], [".md"])).toEqual([]);
});
