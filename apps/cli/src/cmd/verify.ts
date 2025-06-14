import { IVerifyResult, MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';

export interface IVerifyCommandOptions { 
    //
    // Set the path to the database metadata.
    //
    meta?: string;

    //
    // Sets the path to private key file for encryption.
    //
    key?: string;

    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;

    //
    // Force full verification (bypass cached hash optimization).
    //
    full?: boolean;
}

//
// Command that verifies the integrity of the Photosphere media file database.
//
export async function verifyCommand(dbDir: string, options: IVerifyCommandOptions): Promise<void> {

    configureLog({
        verbose: options.verbose,
    });

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);

    // Get the directory for the database (validates it exists and is a media database)
    const databaseDir = await getDirectoryForCommand('existing', dbDir, options.yes || false);
    
    const metaPath = options.meta || pathJoin(databaseDir, '.db');

    //
    // Configure S3 if the path requires it
    //
    if (!await configureS3IfNeeded(databaseDir)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(metaPath)) {
        await exit(1);
    }

    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    const { storage: assetStorage } = createStorage(databaseDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(metaPath);

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY); 

    registerTerminationCallback(async () => {
        await database.close();
    });    

    await database.load();

    writeProgress(`🔍 Verifying database integrity`);

    const result = await database.verify({ full: options.full || false });

    clearProgressMessage(); // Flush the progress message.

    displayResults(result);

    await exit(0);
}

function displayResults(result: IVerifyResult): void {
    console.log();
    console.log(pc.bold(pc.blue(`📊 Verification Results`)));
    console.log();
    
    console.log(`Total files: ${pc.cyan(result.numFiles.toString())}`);
    console.log(`Total nodes: ${pc.cyan(result.numNodes.toString())}`);
    console.log(`Unmodified: ${pc.green(result.numUnmodified.toString())}`);
    console.log(`Modified: ${result.modified.length > 0 ? pc.red(result.modified.length.toString()) : pc.green('0')}`);
    console.log(`New: ${result.new.length > 0 ? pc.yellow(result.new.length.toString()) : pc.green('0')}`);
    console.log(`Removed: ${result.removed.length > 0 ? pc.red(result.removed.length.toString()) : pc.green('0')}`);
    
    // Show details for problematic files
    if (result.modified.length > 0) {
        console.log();
        console.log(pc.red(`Modified files:`));
        result.modified.slice(0, 10).forEach(file => {
            console.log(`  ${pc.red('●')} ${file}`);
        });
        if (result.modified.length > 10) {
            console.log(pc.gray(`  ... and ${result.modified.length - 10} more`));
        }
    }
    
    if (result.new.length > 0) {
        console.log();
        console.log(pc.yellow(`New files:`));
        result.new.slice(0, 10).forEach(file => {
            console.log(`  ${pc.yellow('+')} ${file}`);
        });
        if (result.new.length > 10) {
            console.log(pc.gray(`  ... and ${result.new.length - 10} more`));
        }
    }
    
    if (result.removed.length > 0) {
        console.log();
        console.log(pc.red(`Removed files:`));
        result.removed.slice(0, 10).forEach(file => {
            console.log(`  ${pc.red('-')} ${file}`);
        });
        if (result.removed.length > 10) {
            console.log(pc.gray(`  ... and ${result.removed.length - 10} more`));
        }
    }
    
    console.log();
    if (result.modified.length === 0 && result.new.length === 0 && result.removed.length === 0) {
        console.log(pc.green(`✅ Database verification passed - all files are intact`));
    } else {
        console.log(pc.yellow(`⚠️  Database verification found issues - see details above`));
    }
}
