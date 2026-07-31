import { buildTree, computeDirectoryHash, hashForPath, MISSING_PATH_HASH, TreeNode } from "../lib/merkle";

test("buildTree produces the same root hash regardless of insertion order", () => {
    const forwards = buildTree(new Map([["a.txt", "h1"], ["dir/b.txt", "h2"], ["dir/c.txt", "h3"]]));
    const backwards = buildTree(new Map([["dir/c.txt", "h3"], ["dir/b.txt", "h2"], ["a.txt", "h1"]]));

    expect(forwards.hash).toBe(backwards.hash);
});

test("buildTree produces a different root hash when one file's content hash changes", () => {
    const before = buildTree(new Map([["a.txt", "h1"], ["dir/b.txt", "h2"]]));
    const after = buildTree(new Map([["a.txt", "h1"], ["dir/b.txt", "changed"]]));

    expect(after.hash).not.toBe(before.hash);
});

test("buildTree produces a different root hash when a file is added and when one is removed", () => {
    const base = buildTree(new Map([["a.txt", "h1"], ["dir/b.txt", "h2"]]));
    const added = buildTree(new Map([["a.txt", "h1"], ["dir/b.txt", "h2"], ["dir/c.txt", "h3"]]));
    const removed = buildTree(new Map([["a.txt", "h1"]]));

    expect(added.hash).not.toBe(base.hash);
    expect(removed.hash).not.toBe(base.hash);
});

test("buildTree nests directories correctly for multi-segment paths", () => {
    const tree = buildTree(new Map([["one/two/three/deep.txt", "h1"]]));

    const one = tree.children.get("one")!;
    const two = one.children.get("two")!;
    const three = two.children.get("three")!;
    const deep = three.children.get("deep.txt")!;

    expect(deep.hash).toBe("h1");
    expect(deep.children.size).toBe(0);
    expect(three.hash).not.toBe("");
});

test("hashForPath returns a file's own hash for a file path", () => {
    const tree = buildTree(new Map([["a.txt", "h1"], ["dir/b.txt", "h2"]]));

    expect(hashForPath(tree, "a.txt")).toBe("h1");
    expect(hashForPath(tree, "dir/b.txt")).toBe("h2");
});

test("hashForPath returns a directory hash that reacts only to changes below it", () => {
    const base = buildTree(new Map([["dir/b.txt", "h2"], ["other/c.txt", "h3"]]));
    const changedBelow = buildTree(new Map([["dir/b.txt", "changed"], ["other/c.txt", "h3"]]));
    const changedElsewhere = buildTree(new Map([["dir/b.txt", "h2"], ["other/c.txt", "changed"]]));

    expect(hashForPath(changedBelow, "dir")).not.toBe(hashForPath(base, "dir"));
    expect(hashForPath(changedElsewhere, "dir")).toBe(hashForPath(base, "dir"));
});

test("hashForPath returns MISSING_PATH_HASH for an absent path", () => {
    const tree = buildTree(new Map([["a.txt", "h1"]]));

    expect(hashForPath(tree, "nope")).toBe(MISSING_PATH_HASH);
    expect(hashForPath(tree, "dir/nope.txt")).toBe(MISSING_PATH_HASH);
});

test("hashForPath returns the root hash for an empty path", () => {
    const tree = buildTree(new Map([["a.txt", "h1"], ["dir/b.txt", "h2"]]));

    expect(hashForPath(tree, "")).toBe(tree.hash);
});

test("buildTree returns an empty-hash root for no files", () => {
    const tree = buildTree(new Map());

    expect(tree.children.size).toBe(0);
    expect(tree.hash).toBe("");
});

test("buildTree ignores empty path segments and a path that is only separators", () => {
    const tree = buildTree(new Map([["dir//b.txt", "h2"], ["/", "h3"]]));

    expect(hashForPath(tree, "dir/b.txt")).toBe("h2");
    expect(tree.children.size).toBe(1);
});

test("computeDirectoryHash leaves a childless node's hash untouched", () => {
    //
    // A file node carries its content hash and must not be overwritten by the directory rule.
    //
    const fileNode: TreeNode = { hash: "h1", children: new Map<string, TreeNode>() };

    computeDirectoryHash(fileNode);

    expect(fileNode.hash).toBe("h1");
});

test("computeDirectoryHash fills in a directory hash from its children, bottom up", () => {
    const deepChild: TreeNode = { hash: "h1", children: new Map<string, TreeNode>() };
    const middle: TreeNode = { hash: "", children: new Map([["deep.txt", deepChild]]) };
    const root: TreeNode = { hash: "", children: new Map([["dir", middle]]) };

    computeDirectoryHash(root);

    expect(middle.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(root.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(root.hash).not.toBe(middle.hash);
});

test("computeDirectoryHash is order-independent across a node's children", () => {
    const forwards: TreeNode = {
        hash: "",
        children: new Map([
            ["a.txt", { hash: "h1", children: new Map<string, TreeNode>() }],
            ["b.txt", { hash: "h2", children: new Map<string, TreeNode>() }],
        ]),
    };
    const backwards: TreeNode = {
        hash: "",
        children: new Map([
            ["b.txt", { hash: "h2", children: new Map<string, TreeNode>() }],
            ["a.txt", { hash: "h1", children: new Map<string, TreeNode>() }],
        ]),
    };

    computeDirectoryHash(forwards);
    computeDirectoryHash(backwards);

    expect(forwards.hash).toBe(backwards.hash);
});

test("computeDirectoryHash cannot be fooled by a name and hash running together", () => {
    //
    // The NUL and newline framing is what stops "ab" + "c" hashing the same as "a" + "bc". Without it
    // a rename could leave the directory hash unchanged.
    //
    const left: TreeNode = { hash: "", children: new Map([["ab", { hash: "c", children: new Map<string, TreeNode>() }]]) };
    const right: TreeNode = { hash: "", children: new Map([["a", { hash: "bc", children: new Map<string, TreeNode>() }]]) };

    computeDirectoryHash(left);
    computeDirectoryHash(right);

    expect(left.hash).not.toBe(right.hash);
});
