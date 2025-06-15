import { createStorage } from "storage";
import { MediaFileDatabase } from "api";
import { exit } from "node-utils";
import path from "path";
import pc from "picocolors";

export interface IMerkleTreeCommandOptions {
    meta?: string;
    key?: string;
    verbose?: boolean;
    yes?: boolean;
}

//
// Command to visualize the merkle tree structure
//
export async function merkleTreeCommand(databaseDir: string | undefined, options: IMerkleTreeCommandOptions): Promise<void> {
    
    databaseDir = databaseDir || process.cwd();
    
    try {
        // Set up storage connections
        const { storage: assetStorage } = createStorage(databaseDir);
        
        // Set up metadata directory
        const metadataDir = options.meta || path.join(databaseDir, ".db");
        const { storage: metadataStorage } = createStorage(metadataDir);
        
        // Create database instance
        const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY);
        
        // Load the database
        console.log(pc.blue("Loading database..."));
        await database.load();
        
        // Visualize the merkle tree
        console.log(pc.green("\nMerkle Tree Visualization:"));
        console.log(pc.gray("=".repeat(50)));
        
        const visualization = database.visualizeMerkleTree();
        console.log(visualization);
        
        // Close the database
        await database.close();
        
    } catch (err: any) {
        console.error(pc.red(`Error visualizing merkle tree: ${err.message}`));
        if (options.verbose && err.stack) {
            console.error(pc.red(err.stack));
        }
        await exit(1);
    }
}