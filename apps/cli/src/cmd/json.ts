import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { serializeTreeToJSON } from "adb";

export interface IJsonCommandOptions extends IBaseCommandOptions {
}

//
// Command to serialize the merkle tree to JSON
//
export async function jsonCommand(options: IJsonCommandOptions): Promise<void> {

    const { database } = await loadDatabase(options.db, options, true, true);

    const merkleTree = database.getAssetDatabase().getMerkleTree();
    const json = serializeTreeToJSON(merkleTree.sort);

    console.log(JSON.stringify(json, null, 2));

    await exit(0);
}
