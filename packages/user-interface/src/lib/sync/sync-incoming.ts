import { IApi } from "../../context/api-context";
import { applyOperations } from "../apply-operation";
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
    // Indexeddb databases.
    //
    database: IDatabase;
}

//
// Receive incoming asset updates from the cloud.
//
export async function syncIncoming({ setIds, api, database }: IProps): Promise<void> {

    const lastUpdateCollection = database.collection<ILastUpdateRecord>("last-update");

    for (const setId of setIds) {
        const lastUpdateRecord = await lastUpdateCollection.getOne(setId);
        const journalResult = await api.getJournal(lastUpdateRecord?.lastUpdateTime);
        if (journalResult.journalRecords.length > 0) {
            //
            // Apply incoming changes to the local database.
            //
            await applyOperations(database, journalResult.journalRecords);    
        }
        
        if (journalResult.latestTime !== undefined) {
            //
            // Record the latest update that was received.
            //
            await lastUpdateCollection.setOne({ 
                _id: setId, 
                lastUpdateTime: journalResult.latestTime 
            });
        }

        console.log(`Processed incoming updates for ${setId}, ${journalResult.journalRecords.length} ops`);
    }    
}
