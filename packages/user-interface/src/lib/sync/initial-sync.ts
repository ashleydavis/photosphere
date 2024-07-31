import { IAsset } from "defs";
import { IDatabase } from "../database/database";
import { IApi } from "../../context/api-context";
import { IGalleryItem } from "../gallery-item";
import { ILastUpdateRecord } from "./last-update-record";
import { sleep } from "../sleep";

//
// Gets the sorting value from the gallery item.
//
export type SortFn = (galleryItem: IGalleryItem) => any;

//
// Does the initial asset load and synchronization.
//
export async function initialSync(database: IDatabase, setId: string, api: IApi, setIndex: number, setAssets: (assets: IGalleryItem[], setIndex: number) => boolean, sortFn?: SortFn): Promise<void> {
    const localCollection = database.collection<IAsset>("metadata");
    let assets = await localCollection.getAllByIndex("setId", setId);
    if (assets.length > 0) {
        //
        // Sort assets loaded from indexeddb.
        //
        if (sortFn) {
            assets.sort((a, b) => {
                const sortA = sortFn(a);
                const sortB = sortFn(b);
                if (sortA === undefined) {
                    if (sortB === undefined) {
                        return 0; // Equal.
                    }
                    else {
                        return 1; // a has no sort value, so it comes last.
                    }
                }
                else if (sortB === undefined) {
                    return -1; // b has no sort value, so it comes last.
                }
    
                if (sortA < sortB) {
                    return 1; // a comes after b.
                }
                else if (sortA > sortB) {
                    return -1; // a comes before b.
                }
                else {
                    return 0; // a and b are equal.
                }
            });
        }

        setAssets(assets, setIndex);
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
            const records = await api.getAll<IAsset>(setId, "metadata", skip, pageSize);
            if (records.length === 0) {
                // No more records.
                break;
            }

            skip += pageSize;
            assets = assets.concat(records);           
            if (!setAssets(assets, setIndex)) {
                // Request to abort asset loading.
                return;
            }

            //
            // Wait a moment before starting the next request.
            //
            await sleep(100);
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
        for (const asset of assets) {
            await localCollection.setOne(asset);
        }
    }
}
