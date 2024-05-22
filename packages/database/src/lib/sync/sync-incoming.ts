import { IApi } from "../api";
import { IAssetSink } from "../asset-sink";
import { IDatabase } from "../database";
import { IDatabases } from "../databases";
import { IUpdateIdRecord } from "./update-id-record";

interface IProps {
    //
    // Collections for which to receive updates.
    //
    collectionIds: string[];    

    //
    // The interface to the backend.
    //
    api: IApi;

    //
    // The local user database.
    //
    userDatabase: IDatabase;

    //
    // For recording incoming updates to the local database.
    //
    indexeddbSink: IAssetSink;

    //
    // Interface to cloud databases.
    //
    cloudDatabases: IDatabases;
}

//
// Receive incoming asset uploads and updates from the cloud.
//
export async function syncIncoming({ collectionIds, api, userDatabase, indexeddbSink, cloudDatabases }: IProps): Promise<void> {
    //
    // Retreive updates for the collections we have access to, but only
    // from the latest update that was received.
    //
    for (const collectionId of collectionIds) {
        const lastUpdateIdCollection = userDatabase.collection<IUpdateIdRecord>("last-update-id");
        const lastUpdateIdRecord = await lastUpdateIdCollection.getOne(collectionId);
        const journalResult = await api.getJournal(collectionId, lastUpdateIdRecord?.lastUpdateId);

        if (journalResult.ops.length === 0) {
            // Nothing to do.
            break;
        }

        //
        // Apply incoming changes to the local database.
        //
        cloudDatabases.submitOperations(journalResult.ops.map(journalRecord => ({
            databaseName: collectionId,
            collectionName: journalRecord.collectionName,
            recordId: journalRecord.recordId,
            op: journalRecord.op,
        })));
            
        if (journalResult.latestUpdateId !== undefined) {
            //
            // Record the latest update that was received.
            //
            await lastUpdateIdCollection.setOne(collectionId, { 
                _id: collectionId, 
                lastUpdateId: journalResult.latestUpdateId 
            });
        }
        
        console.log(`Processed incoming updates for ${collectionId}: ${journalResult.ops.length} ops`);
    }
}
