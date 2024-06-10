import { IApi } from "../../context/api-context";
import { IDatabase } from "../database/database";
import { ILastUpdateRecord } from "./last-update-record";

interface IProps {
    //
    // Collections to synchronize.
    //
    setIds: string[];

    //
    // The interface to the backend.
    //
    api: IApi;

    //
    // Local database to poplulate.
    //
    database: IDatabase;
}

//
// Perform the initial database synchronization.
//
export async function initialSync({ setIds, api, database }: IProps): Promise<void> {

    //
    // Records the time of the latest update for the set.
    // This should be done before the initial sync to avoid missing updates.
    //
    const latestTime = await api.getLatestTime();

    for (const setId of setIds) {
        const assets = await database.collection("metadata").getAllByIndex("setId", setId); //TODO: There is probably a more efficient way to probe the db.
        if (assets.length > 0) {
            // If we have assets in this collection we have already sync'd it.
            continue;
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

        for (const collectionName of ["metadata", "hashes"]) {
            let skip = 0;
            const pageSize = 1000;
            while (true) {
                const records = await api.getAll(setId, collectionName, skip, pageSize);
                if (records.length === 0) {
                    // No more records.
                    break;
                }

                skip += pageSize;

                const localCollection = database.collection(collectionName);
                for (const record of records) {
                    await localCollection.setOne(record); // Store it locally.
                }
            }
        }
    }
}

