import { IAsset } from "defs";
import { IDatabase } from "../database/database";
import { IApi } from "../../context/api-context";
import { IGalleryItem } from "../gallery-item";
import { ILastUpdateRecord } from "./last-update-record";

//
// Does the initial asset load and synchronization.
//
export async function initialSync(database: IDatabase, setId: string, api: IApi, setAssets: (assets: IGalleryItem[]) => void): Promise<void> {
    let assets = await database.collection<IAsset>("metadata").getAllByIndex("setId", setId);
    if (assets.length > 0) {
        setAssets(assets);
    }
    else {
        //
        // Records the time of the latest update for the set.
        // This should be done before the initial sync to avoid missing updates.
        //
        const latestTime = await api.getLatestTime();

        //
        // Load the assets from the cloud into memory.
        //
        let skip = 0;
        const pageSize = 1000;
        while (true) {
            const records = await api.getAll<IAsset>(setId, "metadata", skip, pageSize);
            if (records.length === 0) {
                // No more records.
                break;
            }

            skip += pageSize;
            assets = assets.concat(records);           
            setAssets(assets);
        }

        if (latestTime !== undefined) {
            //
            // Record the latest time where updates were received.
            //
            database.collection<ILastUpdateRecord>("last-update").setOne({
                _id: setId,
                lastUpdateTime: latestTime,
            });
        }

        //
        // Save the assets to the local database.
        //
        const localCollection = database.collection("metadata");
        for (const asset of assets) {
            await localCollection.setOne(asset);
        }
    }
}
