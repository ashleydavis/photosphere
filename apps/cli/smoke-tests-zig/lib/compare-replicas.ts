//
// Compares a database replicated by the TypeScript CLI with the same database replicated by the Zig CLI.
//
// Usage (from apps/cli): bun run smoke-tests-zig/lib/compare-replicas.ts <ts-replica-dir> <zig-replica-dir>
//
// Checks:
//   - Both replicas contain exactly the same set of files.
//   - Every file that is not a merkle tree is byte-identical.
//   - Every merkle tree file loads to the same tree in both replicas, ignoring the lastModified times
//     (these are file modification times, which differ between any two replications, even two by TypeScript).
//   - Every merkle tree file written by Zig is byte-identical to what TypeScript writes when it saves the same tree.
//
// Exits with code 0 when the replicas match, otherwise prints every difference and exits with code 1.
//

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadTree, saveTree } from "merkle-tree";
import { FileStorage } from "storage";

//
// Lists every file under a directory, as paths relative to that directory, sorted.
//
function listFiles(rootDir: string): string[] {
    const results: string[] = [];
    const pending: string[] = [""];
    while (pending.length > 0) {
        const relativeDir = pending.pop()!;
        for (const entry of fs.readdirSync(path.join(rootDir, relativeDir), { withFileTypes: true })) {
            const relativePath = relativeDir ? `${relativeDir}/${entry.name}` : entry.name;
            if (entry.isDirectory()) {
                pending.push(relativePath);
            }
            else {
                results.push(relativePath);
            }
        }
    }
    return results.sort();
}

//
// Gets the merkle tree type code for a file, or undefined when the file is not a merkle tree.
//
function getTreeTypeCode(relativePath: string): string | undefined {
    if (relativePath === ".db/files.dat") {
        return "FTRE";
    }
    if (relativePath === ".db/bson/db.dat") {
        return "BDBT";
    }
    if (/^\.db\/bson\/collections\/[^/]+\/collection\.dat$/.test(relativePath)) {
        return "COLT";
    }
    if (/^\.db\/bson\/collections\/[^/]+\/shards\/[^/]+\.dat$/.test(relativePath)) {
        return "COLT";
    }
    return undefined;
}

//
// Converts a loaded tree to JSON with Buffers as hex and the lastModified times removed.
//
function treeToComparableJson(tree: any): string {
    return JSON.stringify(tree, (key: string, value: any) => {
        if (key === "lastModified") {
            return undefined;
        }
        if (value && value.type === "Buffer" && Array.isArray(value.data)) {
            return Buffer.from(value.data).toString("hex");
        }
        return value;
    }, 2);
}

//
// Compares the two replicas and returns the list of differences found.
//
async function compareReplicas(tsReplicaDir: string, zigReplicaDir: string): Promise<string[]> {
    const differences: string[] = [];
    const storage = new FileStorage("");
    const tsFiles = listFiles(tsReplicaDir);
    const zigFiles = listFiles(zigReplicaDir);
    const tsFileSet = new Set(tsFiles);
    const zigFileSet = new Set(zigFiles);

    for (const relativePath of tsFiles) {
        if (!zigFileSet.has(relativePath)) {
            differences.push(`Missing from the Zig replica: ${relativePath}`);
        }
    }
    for (const relativePath of zigFiles) {
        if (!tsFileSet.has(relativePath)) {
            differences.push(`Only in the Zig replica: ${relativePath}`);
        }
    }

    const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), "compare-replicas-"));
    try {
        for (const relativePath of tsFiles) {
            if (!zigFileSet.has(relativePath)) {
                continue;
            }
            const tsFilePath = path.join(tsReplicaDir, relativePath);
            const zigFilePath = path.join(zigReplicaDir, relativePath);
            const typeCode = getTreeTypeCode(relativePath);
            if (typeCode === undefined) {
                if (!fs.readFileSync(tsFilePath).equals(fs.readFileSync(zigFilePath))) {
                    differences.push(`Bytes differ: ${relativePath}`);
                }
                continue;
            }

            const tsTree = await loadTree(tsFilePath, storage, typeCode);
            const zigTree = await loadTree(zigFilePath, storage, typeCode);
            if (!tsTree || !zigTree) {
                differences.push(`Failed to load merkle tree: ${relativePath}`);
                continue;
            }
            if (treeToComparableJson(tsTree) !== treeToComparableJson(zigTree)) {
                differences.push(`Merkle tree content differs (ignoring lastModified): ${relativePath}`);
            }

            const resavedPath = path.join(scratchDir, relativePath.replace(/\//g, "_"));
            await saveTree(resavedPath, zigTree, storage, typeCode);
            if (!fs.readFileSync(resavedPath).equals(fs.readFileSync(zigFilePath))) {
                differences.push(`Zig wrote different bytes than TypeScript writes for the same tree: ${relativePath}`);
            }
        }
    }
    finally {
        fs.rmSync(scratchDir, { recursive: true, force: true });
    }

    return differences;
}

//
// Entry point.
//
async function main(): Promise<void> {
    const [tsReplicaDir, zigReplicaDir] = process.argv.slice(2);
    if (!tsReplicaDir || !zigReplicaDir) {
        console.error("Usage: bun run smoke-tests-zig/lib/compare-replicas.ts <ts-replica-dir> <zig-replica-dir>");
        process.exit(2);
    }

    const differences = await compareReplicas(tsReplicaDir, zigReplicaDir);
    if (differences.length > 0) {
        console.log(`Replicas differ (${differences.length} differences):`);
        for (const difference of differences) {
            console.log(`  ${difference}`);
        }
        process.exit(1);
    }

    console.log("Replicas match");
}

main();
