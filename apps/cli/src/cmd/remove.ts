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
    try {
        // Validate inputs
        if (!assetId) {
            throw new Error("Asset ID is required");
        }

        const dbPath = options.db || process.cwd();
        log.info(`Removing asset ${pc.cyan(assetId)} from database at ${pc.yellow(dbPath)}`);

        // Load the database using shared function
        const { database } = await loadDatabase(dbPath, options);

        // Remove the asset using the comprehensive removal method
        log.info(`Removing asset with ID: ${pc.cyan(assetId)}`);
        await database.remove(assetId);

        // Save the updated database
        await database.close();

        log.info(pc.green(`✓ Successfully removed asset ${assetId} from database`));

    } catch (error) {
        log.error(pc.red(`Remove failed: ${error instanceof Error ? error.message : String(error)}`));
        await exit(1);
    }

    await exit(0);
}