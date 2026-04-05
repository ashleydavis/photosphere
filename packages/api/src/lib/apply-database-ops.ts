import type { IBsonCollection } from "bdb";
import type { IAsset, IDatabaseOp } from "defs";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import { createStorage } from "storage";
import { acquireWriteLock, releaseWriteLock } from "./write-lock";
import { createLazyDatabaseStorage, createMediaFileDatabase, loadSortIndexes } from "./media-file-database";

//
// Groups operations by target database path (databaseId on each op).
//
export function groupOpsByDatabaseId(ops: IDatabaseOp[]): Map<string, IDatabaseOp[]> {
    const groups = new Map<string, IDatabaseOp[]>();
    for (const op of ops) {
        const existing = groups.get(op.databaseId);
        if (existing) {
            existing.push(op);
        }
        else {
            groups.set(op.databaseId, [ op ]);
        }
    }
    return groups;
}

//
// Applies a single metadata operation using the given metadata collection.
//
export async function applyMetadataDatabaseOps(metadataCollection: IBsonCollection<IAsset>, ops: IDatabaseOp[]): Promise<void> {
    for (const op of ops) {
        if (op.collectionName !== "metadata") {
            throw new Error(`Unsupported collection "${op.collectionName}". Only "metadata" is supported.`);
        }

        if (op.op.type === "set") {
            const { _id: _ignoredFromFields, ...updates } = op.op.fields;
            await metadataCollection.updateOne(op.recordId, updates, { upsert: true });
        }
        else if (op.op.type === "push") {
            const pushOp = op.op;
            const existing = await metadataCollection.getOne(op.recordId);
            if (!existing) {
                throw new Error(`Cannot push: metadata record "${op.recordId}" does not exist.`);
            }
            const previous = (existing as any)[pushOp.field];
            const asArray = Array.isArray(previous) ? [ ...previous ] : [];
            if (!asArray.includes(pushOp.value)) {
                asArray.push(pushOp.value);
            }
            const partial = { [pushOp.field]: asArray };
            await metadataCollection.updateOne(op.recordId, partial);
        }
        else if (op.op.type === "pull") {
            const pullOp = op.op;
            const existing = await metadataCollection.getOne(op.recordId);
            if (!existing) {
                throw new Error(`Cannot pull: metadata record "${op.recordId}" does not exist.`);
            }
            const previous = (existing as any)[pullOp.field];
            const asArray = Array.isArray(previous) ? previous : [];
            const filtered = asArray.filter(item => item !== pullOp.value);
            const partial = { [pullOp.field]: filtered };
            await metadataCollection.updateOne(op.recordId, partial);
        }
    }
}

//
// Persists metadata changes to disk for one or more databases (grouped by each op's databaseId).
// uuidGenerator and timestampProvider are passed through to the BSON database; sessionId owns .db/write.lock during writes.
//
export async function applyDatabaseOps(uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider, sessionId: string, ops: IDatabaseOp[]): Promise<void> {
    if (ops.length === 0) {
        return;
    }

    const groups = groupOpsByDatabaseId(ops);
    for (const [ databasePath, pathOps ] of groups) {
        const { rawStorage } = createStorage(databasePath, undefined, undefined);
        const assetStorage = await createLazyDatabaseStorage(databasePath);
        const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
        await loadSortIndexes(assetStorage, database.metadataCollection);

        if (!await acquireWriteLock(rawStorage, sessionId)) {
            throw new Error("Failed to acquire write lock.");
        }

        try {
            await applyMetadataDatabaseOps(database.metadataCollection, pathOps);
            await database.bsonDatabase.commit();
        }
        finally {
            await releaseWriteLock(rawStorage);
        }
    }
}
