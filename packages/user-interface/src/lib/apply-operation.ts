import { createReverseChronoTimestamp } from "./timestamp";
import { IDatabase } from "./database/database";
import { IDatabases } from "./database/databases";
import { uuid } from "./uuid";
import { IDatabaseOp, IDatabaseOpRecord, IOpSelection } from "defs";

//
// Applies a single database operation to the field set for a database record.
//
export function applyOperation(op: IOpSelection, fields: any): void {
    switch (op.type) {
        case "set": {
            for (const [name, value] of Object.entries(op.fields)) {
                if (value === null || value === undefined || Number.isNaN(value)) {
                    continue; // Do not set null or undefined values.
                }
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
// Submits operations to change various databases.
//
export async function applyOperations(databases: IDatabases, databaseOps: IDatabaseOp[]): Promise<void> {
    for (const databaseOp of databaseOps) {
        const database = databases.database(databaseOp.setId);
        const collection = database.collection(databaseOp.collectionName)
        const record = await collection.getOne(databaseOp.recordId);

        let fields = record as any || {};
        if (!record) {
            // Set the record id when upserting. 
            fields._id = databaseOp.recordId;
            fields.setId = databaseOp.setId;
        }

        applyOperation(databaseOp.op, fields);

        await collection.setOne(databaseOp.recordId, fields);
    }
}    
