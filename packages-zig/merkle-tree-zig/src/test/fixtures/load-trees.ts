//
// Loads tree files with the TypeScript merkle-tree package and prints their summaries as JSON.
// The Zig golden tests run this on the trees Zig saved, to prove TypeScript loads them identically.
//
// Usage: bun run src/test/fixtures/load-trees.ts <file>:<typeCode> [<file>:<typeCode> ...]
//

import * as path from "path";
import { loadTree } from "merkle-tree";
import { FileStorage } from "storage";
import { summarizeTree, type ITreeSummary } from "./summary";

//
// Loads every tree given on the command line and prints the summaries.
//
async function main(): Promise<void> {
    const storage = new FileStorage("");
    const summaries: ITreeSummary[] = [];
    for (const argument of process.argv.slice(2)) {
        const separator = argument.lastIndexOf(":");
        const filePath = path.resolve(argument.slice(0, separator));
        const typeCode = argument.slice(separator + 1);
        const tree = await loadTree(filePath, storage, typeCode);
        if (!tree) {
            throw new Error(`Tree not found: ${filePath}`);
        }
        summaries.push(summarizeTree(tree));
    }
    process.stdout.write(JSON.stringify(summaries));
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
