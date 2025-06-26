import pc from "picocolors";
import { exit } from "node-utils";
import { formatBytes } from "../lib/format";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface ISummaryCommandOptions extends IBaseCommandOptions {
}

//
// Command that displays a summary of the Photosphere media file database.
//
export async function summaryCommand(options: ISummaryCommandOptions): Promise<void> {
    
    const { database } = await loadDatabase(options.db, options);

    // Get database summary information
    const summary = await database.getDatabaseSummary();

    console.log(pc.bold(pc.blue(`📊 Database Summary`)));
    console.log();
    console.log(`Files imported: ${pc.green(summary.totalAssets.toString())}`);
    console.log(`Total files: ${pc.green(summary.totalFiles.toString())}`);
    console.log(`Total size: ${pc.green(formatBytes(summary.totalSize))}`);
    console.log(`Tree root hash: ${pc.gray(summary.fullHash)}`);

    // Show follow-up commands
    console.log();
    console.log(pc.bold('Next steps:'));
    console.log(`  ${pc.cyan('psi verify')}                    Verify the integrity of all files in the database`);
    console.log(`  ${pc.cyan('psi add <paths>')}               Add more files to your database`);
    console.log(`  ${pc.cyan('psi replicate --dest <path>')}   Create a backup copy of your database`);
    console.log(`  ${pc.cyan('psi ui')}                        Open the web interface to browse your media`);

    await exit(0);
}

