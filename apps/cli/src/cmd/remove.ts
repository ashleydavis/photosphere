import pc from "picocolors";
import { exit } from "node-utils";
import { log } from "utils";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface IRemoveCommandOptions extends IBaseCommandOptions {
    // No additional options needed beyond base options
}

//
// Command that removes a particular asset by ID from the database.
//
export async function removeCommand(assetId: string, options: IRemoveCommandOptions): Promise<void> {
    const dbPath = options.db || process.cwd();

    // Load the database using shared function
    const { database } = await loadDatabase(dbPath, options, false);

    // Remove the asset using the comprehensive removal method
    await database.remove(assetId);

    log.info(pc.green(`✓ Successfully removed asset ${assetId} from database`));

    await exit(0);
}