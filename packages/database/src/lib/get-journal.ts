import { IDatabaseOpRecord, IOpSelection } from "../defs/ops";
import { binarySearch } from "./binary-search";
import { IDatabase } from "./database";
import { IPage } from "./database-collection";

//
// Records a database operation against a particular record.
//
export interface IDatabaseOpResult {
    //
    // The id of the asset to which the operation is applied.
    //
    assetId: string;

    //
    // The operation that was applied to the record.
    //
    op: IOpSelection;
}

//
// The result of get the database journal.
//
export interface IJournalResult {
    //
    // Operations recorded against the collection.
    //
    ops: IDatabaseOpResult[];

    //
    // The id of the latest update that has been retreived.
    //
    latestUpdateId?: string;
}

//
// Gets the journal of operations that have been applied to the database.
//
export async function getJournal(database: IDatabase, clientId: string, lastUpdateId?: string): Promise<IJournalResult> {

    let allRecords: IDatabaseOpRecord[] = [];
    let done = false;
    let latestUpdateId: string | undefined = undefined;
    let next: string | undefined = undefined;
    const journalCollection = database.collection<IDatabaseOpRecord>("journal");

    while (!done) { 
        const result: IPage<string> = await journalCollection.listAll(1000, next);
        next = result.next;
        
        if (result.next === undefined) {
            // No more journal records to fetch.
            done = true;
        }
        
        let journalRecordIds = result.records;
        if (latestUpdateId === undefined && journalRecordIds.length > 0) {
            latestUpdateId = journalRecordIds[0];
        }

        //
        // Only deliver updates that are newer than the record that was last seen.
        //
        if (lastUpdateId !== undefined) {
            const cutOffIndex = binarySearch(journalRecordIds, lastUpdateId);
            if (cutOffIndex !== undefined) {
                journalRecordIds = journalRecordIds.slice(0, cutOffIndex);
                done = true; // We found the requested update id, no need to continue searching through the journal. 
            }
        }

        const journalRecordPromises = journalRecordIds.map(async id => {
            const assetRecord = await journalCollection.getOne(id);
            return assetRecord!; // These records should always exist, since we just looked them up.
        });

        let journalRecords = await Promise.all(journalRecordPromises);

        // Don't deliver updates that originated from the requesting client.
        journalRecords = journalRecords.filter(journalRecord => journalRecord.clientId !== clientId); 
        allRecords = allRecords.concat(journalRecords);
    }

    //
    // Operations are pulled out in reverse chronological order, this puts them in chronological order.
    //
    allRecords.reverse(); 

    return {
        ops: allRecords.map(journalRecord => {
            return {
                assetId: journalRecord.recordId,
                op: journalRecord.op,
            };
        }),
        latestUpdateId,
    };
}