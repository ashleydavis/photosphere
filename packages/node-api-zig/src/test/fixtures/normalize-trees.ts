//
// Loads every merkle tree file (.dat) of a database with the TypeScript merkle-tree package, sets the lastModified
// of every leaf to 0 (the timestamps are the only values that differ between two replications), and saves the
// tree with the TypeScript saveTree under the same path in an output directory. The Zig parity tests do the same
// with the Zig port and compare the bytes of the two outputs.
// Usage: bun run normalize-trees.ts <database path> <output directory> [key]
//

import { createStorage, walkDirectory } from "storage";
import { loadTree, saveTree, SortNode } from "merkle-tree";
import { openStorage } from "node-api";

//
// Gets the type code of a merkle tree file, or undefined when the file is not a merkle tree.
//
function treeTypeCode(fileName: string): string | undefined {
    if (fileName === ".db/files.dat") {
        return "FTRE";
    }
    if (fileName === ".db/bson/db.dat") {
        return "BDBT";
    }
    if (fileName.startsWith(".db/bson/collections/") && fileName.endsWith(".dat")) {
        return "COLT";
    }
    return undefined;
}

//
// Sets the lastModified of every node that has one to 0.
//
function clearTimestamps(node: SortNode | undefined): void {
    if (!node) {
        return;
    }
    if (node.lastModified !== undefined) {
        node.lastModified = new Date(0);
    }
    clearTimestamps(node.left);
    clearTimestamps(node.right);
}

//
// Normalizes the trees.
//
async function main(): Promise<void> {
    const [databasePath, outputDir, key] = process.argv.slice(2);
    const { storage, rawStorage } = await openStorage(databasePath, key || undefined);
    const { storage: outputStorage } = createStorage(outputDir);
    for await (const { fileName } of walkDirectory(rawStorage, ".db", [])) {
        const typeCode = treeTypeCode(fileName);
        if (!typeCode) {
            continue;
        }
        const tree = await loadTree<any>(fileName, storage, typeCode);
        if (!tree) {
            throw new Error(`Failed to load ${fileName}`);
        }
        clearTimestamps(tree.sort);
        await saveTree(fileName, tree, outputStorage, typeCode);
    }
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
