import pc from "picocolors";
import { exit } from "node-utils";
import { log } from "utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { removeAsset } from "api";

export interface IRemoveCommandOptions extends IBaseCommandOptions {
    // No additional options needed beyond base options
}

//
// Command that removes a particular asset by ID from the database.
//
export async function removeCommand(context: ICommandContext, assetId: string, options: IRemoveCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const dbPath = options.db || process.cwd();

    // Load the database using shared function
    const { assetStorage, metadataStorage, metadataCollection } = await loadDatabase(dbPath, options, false, uuidGenerator, timestampProvider, sessionId);

    // Remove the asset using the comprehensive removal method
    await removeAsset(assetStorage, metadataStorage, sessionId, metadataCollection, assetId, true);

    log.info(pc.green(`✓ Successfully removed asset ${assetId} from database`));

    await exit(0);
}