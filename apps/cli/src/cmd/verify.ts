import { IVerifyResult } from "api";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface IVerifyCommandOptions extends IBaseCommandOptions {
    //
    // Force full verification (bypass cached hash optimization).
    //
    full?: boolean;
}

//
// Command that verifies the integrity of the Photosphere media file database.
//
export async function verifyCommand(dbDir: string, options: IVerifyCommandOptions): Promise<void> {
    
    const database = await loadDatabase(dbDir, options);

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
    
    console.log(`Total files: ${pc.cyan(result.numAssets.toString())}`);
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
