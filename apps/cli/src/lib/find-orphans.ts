import { IStorage } from "storage";
import { IMerkleTree } from "merkle-tree";
import { traverseTreeAsync, SortNode } from "merkle-tree";
import { walkDirectory } from "storage";
import { log } from "utils";

//
// Finds files that exist in storage but are no longer in the merkle tree.
// Returns an array of orphaned file paths.
//
export async function findOrphans(
    assetStorage: IStorage,
    merkleTree: IMerkleTree<any>
): Promise<string[]> {
    const orphans: string[] = [];
    
    // Collect all file names from the merkle tree
    const merkleFileNames = new Set<string>();
    
    if (merkleTree.sort) {
        await traverseTreeAsync<SortNode>(merkleTree.sort, async (node) => {
            if (node.name) {
                merkleFileNames.add(node.name);
            }
            return true;
        });
    }
    
    log.verbose(`Found ${merkleFileNames.size} files in merkle tree`);
    
    // Walk through asset storage and find files not in merkle tree
    // Ignore .db directory (metadata storage) and metadata directory (BSON database storage)
    const ignorePatterns = [/^\/?\.db/, /^\/?metadata/, /\.DS_Store/];
    
    for await (const file of walkDirectory(assetStorage, "/", ignorePatterns)) {
        // Normalize path: remove leading slash to match merkle tree format
        let fileName = file.fileName;
        if (fileName.startsWith("/")) {
            fileName = fileName.slice(1);
        }
        
        // Skip if file is in merkle tree
        if (merkleFileNames.has(fileName)) {
            continue;
        }
        
        // This is an orphan
        orphans.push(fileName);
    }
    
    return orphans;
}

