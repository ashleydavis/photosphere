import { IAsset } from "defs";
import { IDatabase } from "../database/database";
import { IApi } from "../../context/api-context";
import { ILastUpdateRecord } from "./last-update-record";
import { IAssetRecord } from "../../def/asset-record";

//
// Does the initial asset load and synchronization.
//
export async function initialSync(database: IDatabase, setId: string, api: IApi, setIndex: number, 
    setAssets: (assets: IAsset[]) => void,
    shouldContinue?: (setIndex: number) => boolean,
        ): Promise<void> {
    //
    // Load from local collection.
    //
    const localCollection = database.collection<IAsset>("metadata")
    let allAssets = await localCollection.getAllByIndex("setId", setId);
    if (allAssets.length > 0) {
        setAssets(allAssets);
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
            //
            // Get a page of assets from the backend.
            // Assumes the backend gives us the assets in sorted order.
            //
            const page = await api.getAll<IAsset>(setId, "metadata", skip, pageSize);
            if (page.length === 0) {
                // No more records.
                break;
            }

            skip += pageSize;
            if (shouldContinue && !shouldContinue(setIndex)) {
                // Request to abort asset loading.
                return;
            }     

            setTimeout(() => {
                setAssets(page); // Starts the next request before setting the new assets.
            }, 0);

            allAssets = allAssets.concat(page);    
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
        for (const asset of allAssets) {
            await localCollection.setOne(asset);
        }
    }
}
