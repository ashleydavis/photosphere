import { IApi } from "../../context/api-context";
import { applyOperations } from "../apply-operation";
import { IIndexeddbDatabases } from "../database/indexeddb/indexeddb-databases";
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
    indexeddbDatabases: IIndexeddbDatabases;
}

//
// Receive incoming asset updates from the cloud.
//
export async function syncIncoming({ setIds, api, indexeddbDatabases }: IProps): Promise<void> {

    const userDatabase = indexeddbDatabases.database("user");
    const lastUpdateCollection = userDatabase.collection<ILastUpdateRecord>("last-update");

    for (const setId of setIds) {
        const lastUpdateRecord = await lastUpdateCollection.getOne(setId);
        const journalResult = await api.getJournal(lastUpdateRecord?.lastUpdateTime);
        if (journalResult.journalRecords.length > 0) {
            //
            // Apply incoming changes to the local database.
            //
            await applyOperations(indexeddbDatabases, journalResult.journalRecords);    
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
