import dayjs from "dayjs";
import { IDatabaseOp, IDatabaseOpRecord, IOpSelection } from "../defs/ops";
import { createReverseChronoTimestamp } from "./timestamp";
import { IDatabase } from "./database";
import { IDatabaseCollection } from "./database-collection";

//
// Applies a single database operation to the field set for a database record.
//
export function applyOperation(op: IOpSelection, fields: any): void {
    switch (op.type) {
        case "set": {
            for (const [name, value] of Object.entries(op.fields)) {
                fields[name] = value;
            }
            break;
        }

        case "push": {
            if (!fields[op.field]) {
                fields[op.field] = [];
            }
            if (fields[op.field].includes(op.value)) {
                // Do not push the same value more than once.
                break;
            }
            fields[op.field].push(op.value);
            break;
        }

        case "pull": {
            if (!fields[op.field]) {
                fields[op.field] = [];
            }
            fields[op.field] = fields[op.field].filter((v: any) => v !== op.value);
            break;
        }

        default: {
            throw new Error(`Invalid operation type: ${(op as any).type}`);
        }
    }
}

//
// Applies an operation to a database collection.
//
export async function applyOperationToCollection(collection: IDatabaseCollection, databaseOp: IDatabaseOp): Promise<void> {
    const record = await collection.getOne(databaseOp.recordId);

    let updatedAsset = record as any || {};

    if (!record) {
        // Set the asset id when upserting.
        updatedAsset._id = databaseOp.recordId;
    }

    applyOperation(databaseOp.op, updatedAsset);

    await collection.setOne(databaseOp.recordId, updatedAsset);
}

//
// Applies an operation to the database.
//
export async function applyOperationToDb(database: IDatabase, databaseOp: IDatabaseOp, clientId: string): Promise<void> {
    const databaseOpRecord: IDatabaseOpRecord = {
        serverTime: dayjs().toISOString(),
        clientId,
        collectionName: databaseOp.collectionName,
        recordId: databaseOp.recordId,
        op: databaseOp.op,
    };
    
    const journalRecordId = createReverseChronoTimestamp(new Date());
    const journalCollection = database.collection<IDatabaseOpRecord>("journal");
    await journalCollection.setOne(journalRecordId, databaseOpRecord);

    const recordCollection = database.collection(databaseOp.collectionName);
    await applyOperationToCollection(recordCollection, databaseOp);
}    
