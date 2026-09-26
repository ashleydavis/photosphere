//
// Summaries of merkle trees shared by the fixture generator (generate.ts) and the reverse check (load-trees.ts).
// The Zig tests build the same summaries (see golden.test.zig) and compare them field by field.
//

import { serialize } from "bson";
import type { IMerkleTree, MerkleNode, SortNode } from "merkle-tree";

//
// Everything a loaded or built tree contains, in a form both TypeScript and Zig can produce exactly.
//
export interface ITreeSummary {
    //
    // The tree id (UUID).
    //
    id: string;

    //
    // The version of the tree file format.
    //
    version: number;

    //
    // True when the merkle tree must be rebuilt.
    //
    dirty: boolean;

    //
    // The database metadata as BSON hex (null when the tree has no metadata).
    //
    metadataBson: string | null;

    //
    // The shape of the sort tree: a leaf is its name, an internal node is "(left,right)".
    //
    sortShape: string;

    //
    // Every sort node in pre-order: "nodeCount|leafCount|size|minName|name|contentHash hex|lastModified ms".
    //
    sortNodes: string[];

    //
    // Every merkle node in pre-order: "nodeCount|hash hex|name".
    //
    merkleNodes: string[];
}

//
// The shape of a sort tree.
//
function sortShape(node: SortNode | undefined): string {
    if (!node) {
        return "";
    }
    if (!node.left && !node.right) {
        return node.name ?? "?";
    }
    return `(${sortShape(node.left)},${sortShape(node.right)})`;
}

//
// Adds the sort nodes in pre-order.
//
function collectSortNodes(node: SortNode | undefined, output: string[]): void {
    if (!node) {
        return;
    }
    const contentHash = node.contentHash ? node.contentHash.toString("hex") : "";
    const lastModified = node.lastModified ? node.lastModified.getTime().toString() : "";
    output.push(`${node.nodeCount}|${node.leafCount}|${node.size}|${node.minName}|${node.name ?? ""}|${contentHash}|${lastModified}`);
    collectSortNodes(node.left, output);
    collectSortNodes(node.right, output);
}

//
// Adds the merkle nodes in pre-order.
//
function collectMerkleNodes(node: MerkleNode | undefined, output: string[]): void {
    if (!node) {
        return;
    }
    output.push(`${node.nodeCount}|${node.hash.toString("hex")}|${node.name ?? ""}`);
    collectMerkleNodes(node.left, output);
    collectMerkleNodes(node.right, output);
}

//
// Summarizes a tree.
//
export function summarizeTree(tree: IMerkleTree<any>): ITreeSummary {
    const sortNodes: string[] = [];
    collectSortNodes(tree.sort, sortNodes);
    const merkleNodes: string[] = [];
    collectMerkleNodes(tree.merkle, merkleNodes);
    return {
        id: tree.id,
        version: tree.version,
        dirty: tree.dirty,
        metadataBson: tree.databaseMetadata === undefined ? null : Buffer.from(serialize(tree.databaseMetadata as any)).toString("hex"),
        sortShape: sortShape(tree.sort),
        sortNodes,
        merkleNodes,
    };
}
