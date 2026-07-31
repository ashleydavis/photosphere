import { createHash } from "node:crypto";

//
// Returned for a path that is not in the tree at all. A watched path that does not exist has to hash
// to something stable, so that creating the first file under it registers as a change.
//
export const MISSING_PATH_HASH = "<missing>";

//
// One node in the hash tree. A file node carries its content hash and no children; a directory node
// carries a hash derived from its children.
//
export interface TreeNode {
    //
    // The node's hash: a file's content hash, or a directory's hash over its entries.
    //
    hash: string;

    //
    // The node's children by name. Empty for a file node.
    //
    children: Map<string, TreeNode>;
}

//
// Builds a hash tree over a set of file hashes, so that one lookup answers "has anything under this
// directory changed" without walking the file list again.
//
export function buildTree(fileHashes: Map<string, string>): TreeNode {
    const root: TreeNode = {
        hash: "",
        children: new Map<string, TreeNode>(),
    };

    for (const [relativePath, fileHash] of fileHashes) {
        const segments = relativePath.split("/").filter(segment => segment.length > 0);
        if (segments.length === 0) {
            continue;
        }

        let node = root;
        for (let segmentIndex = 0; segmentIndex < segments.length - 1; segmentIndex++) {
            const segment = segments[segmentIndex];
            let child = node.children.get(segment);
            if (!child) {
                child = {
                    hash: "",
                    children: new Map<string, TreeNode>(),
                };
                node.children.set(segment, child);
            }
            node = child;
        }

        node.children.set(segments[segments.length - 1], {
            hash: fileHash,
            children: new Map<string, TreeNode>(),
        });
    }

    computeDirectoryHash(root);
    return root;
}

//
// Fills in the hash of a directory node and every directory below it, from the bottom up. Entries are
// sorted by name before hashing so the result does not depend on the order the files arrived in.
//
export function computeDirectoryHash(node: TreeNode): void {
    if (node.children.size === 0) {
        return;
    }

    const names = Array.from(node.children.keys()).sort();
    const digest = createHash("sha256");
    for (const name of names) {
        const child = node.children.get(name)!;
        computeDirectoryHash(child);
        digest.update(name);
        digest.update(Buffer.from([0]));
        digest.update(child.hash);
        digest.update("\n");
    }
    node.hash = digest.digest("hex");
}

//
// Returns the hash recorded for a path, whether that path names a file or a directory. An empty path
// returns the root hash, which is the hash of the whole tree.
//
export function hashForPath(root: TreeNode, relativePath: string): string {
    const segments = relativePath.split("/").filter(segment => segment.length > 0);

    let node = root;
    for (const segment of segments) {
        const child = node.children.get(segment);
        if (!child) {
            return MISSING_PATH_HASH;
        }
        node = child;
    }
    return node.hash;
}
