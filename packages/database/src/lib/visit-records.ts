import { IPage } from "../defs/page";
import { IDatabase } from "./database";

export type CallbackFn<RecordT> = (id: string, record: RecordT) => Promise<void>;

//
// Invoke a callback function for every record in the requested collection.
//
export async function visitRecords<RecordT>(database: IDatabase, collectionName: string, callback: CallbackFn<RecordT>): Promise<void> {
    const collection = database.collection<RecordT>(collectionName);
    let next: string | undefined = undefined;
    while (true) {
        const page: IPage<string> = await collection.listAll(1000, next); 
        next = page.next;

        for (const recordId of page.records) {
            const record = await collection.getOne(recordId);
            if (record !== undefined) {
                callback(recordId, record);
            }
        }

        if (next === undefined) {
            break;
        }
    }
}