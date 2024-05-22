import { IDatabaseOp } from "../defs/ops";
import { applyOperation } from "./apply-operation";
import { IDatabase } from "./database";

export interface IDatabases {
    //
    // Gets a database by nane.
    //
    database(databaseName: string): IDatabase;

    //
    // Submits operations to change the database.
    //
    submitOperations(ops: IDatabaseOp[]): Promise<void>;    
}

export abstract class AbstractDatabases {
    //
    // Gets a database by name.
    //   
    abstract database(databaseName: string): IDatabase;

    //
    // Submits operations to change the database.
    //
    async submitOperations(databaseOps: IDatabaseOp[]): Promise<void> {
        for (const databaseOp of databaseOps) {
            const recordId = databaseOp.recordId;
            const database = this.database(databaseOp.databaseName);
            const asset = await database.collection(databaseOp.collectionName).getOne(recordId);
            let fields = asset as any || {};
            if (!asset) {
                // Set the record id when upserting.
                fields._id = recordId;
            }

            applyOperation(databaseOp.op, fields);

            await database.collection(databaseOp.collectionName).setOne(recordId, fields);
        }
    }    
}