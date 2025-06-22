import pc from "picocolors";
import { exit } from "node-utils";
import { formatBytes } from "../lib/format";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface ISummaryCommandOptions extends IBaseCommandOptions {}

//
// Command that displays a summary of the Photosphere media file database.
//
export async function summaryCommand(dbDir: string, options: ISummaryCommandOptions): Promise<void> {
    
    const database = await loadDatabase(dbDir, options);

    // Get database summary information
    const summary = await database.getDatabaseSummary();

    console.log(pc.bold(pc.blue(`📊 Database Summary`)));
    console.log();
    console.log(`Total files: ${pc.green(summary.totalAssets.toString())}`);
    console.log(`Total size: ${pc.green(formatBytes(summary.totalSize))}`);
    console.log(`Tree root hash: ${pc.gray(summary.fullHash)}`);

    await exit(0);
}

