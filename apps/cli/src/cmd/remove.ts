import pc from "picocolors";
import { exit } from "node-utils";
import { log } from "utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";

export interface IRemoveCommandOptions extends IBaseCommandOptions {
    // No additional options needed beyond base options
}

//
// Command that removes a particular asset by ID from the database.
//
export async function removeCommand(context: ICommandContext, assetId: string, options: IRemoveCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const dbPath = options.db || process.cwd();

    const { psi } = await loadDatabase(dbPath, options, uuidGenerator, timestampProvider, sessionId);

    await psi.remove(assetId, true);

    log.info(pc.green(`✓ Successfully removed asset ${assetId} from database`));

    await exit(0);
}