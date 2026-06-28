import path, { join, normalize, resolve, dirname, basename, extname, sep } from "../../shims/node-path";

//
// Unit tests for the POSIX path shim. The storage layer relies on join/dirname/resolve, and the
// mobile-specific rule is that resolve stays sandbox-relative (never forced absolute).
//
describe("node-path shim", () => {

    test("join concatenates and normalises segments", () => {
        expect(join("a", "b", "c")).toBe("a/b/c");
        expect(join("a/", "/b", "c/")).toBe("a/b/c");
        expect(join("a", "", "b")).toBe("a/b");
        expect(join("a", "b/../c")).toBe("a/c");
    });

    test("normalize collapses . and .. and redundant slashes", () => {
        expect(normalize("a//b/./c")).toBe("a/b/c");
        expect(normalize("a/b/../c")).toBe("a/c");
        expect(normalize("/a/b/../c")).toBe("/a/c");
        expect(normalize("")).toBe(".");
    });

    test("resolve stays relative for relative input (mobile sandbox rule)", () => {
        expect(resolve("50-assets")).toBe("50-assets");
        expect(resolve("a", "b", "c")).toBe("a/b/c");
        expect(resolve("a", "./b")).toBe("a/b");
    });

    test("resolve preserves an absolute segment and resets on a later absolute", () => {
        expect(resolve("/root", "sub")).toBe("/root/sub");
        expect(resolve("a", "/abs", "b")).toBe("/abs/b");
    });

    test("dirname returns the parent path", () => {
        expect(dirname("a/b/c")).toBe("a/b");
        expect(dirname("a")).toBe(".");
        expect(dirname("/a")).toBe("/");
        expect(dirname("/a/b")).toBe("/a");
    });

    test("basename returns the final segment and strips an optional suffix", () => {
        expect(basename("a/b/c.txt")).toBe("c.txt");
        expect(basename("a/b/c.txt", ".txt")).toBe("c");
        expect(basename("a/b/c.txt", ".txt")).not.toBe("");
    });

    test("extname returns the extension including the dot", () => {
        expect(extname("a/b/c.txt")).toBe(".txt");
        expect(extname("a/b/c")).toBe("");
        expect(extname(".hidden")).toBe("");
    });

    test("sep is the POSIX separator and the default export carries the same functions", () => {
        expect(sep).toBe("/");
        expect(path.join("a", "b")).toBe("a/b");
        expect(path.dirname("a/b")).toBe("a");
    });
});
