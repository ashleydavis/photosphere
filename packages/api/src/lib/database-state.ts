//
// Database state stored at .db/state.dat.
// Holds runtime values that change as the database is modified, synced, or replicated.
// These are distinct from configuration (.db/config.json, which holds origin): the state file is
// rebuildable from the database's merkle trees, so a missing, empty, or corrupt file is simply
// treated as absent and rebuilt on the next write.
//

import { IStorage } from "storage";
import { save, load, ISerializer, IDeserializer } from "serialization";
import { acquireWriteLock, releaseWriteLock } from "./write-lock";

//
// Path of the database state file.
//
const STATE_PATH = ".db/state.dat";

//
// Four-character type code identifying the state file in the serialization header.
//
const STATE_TYPE_CODE = "DBST";

//
// Current on-disk version of the state file (independent of the merkle-tree version).
//
// Version 2 added the automatic import backfill cursor. Version 1 is still read, so a database
// written by an older build keeps its content hash and sync timestamps instead of losing them and
// forcing a full comparison on the next sync; it simply comes back with no backfill cursor, which
// is the same as never having run automatic import.
//
const STATE_VERSION = 2;

//
// Runtime state for a database.
//
export interface IDatabaseState {
    // Combined merkle root hash of the database content (files-tree root combined with bson-db-tree root).
    // Two databases with the same content hash are identical, so this is used to skip a sync with no differences.
    contentHash?: Buffer;
    // ISO date-time when the database was last modified locally (add, remove, edit metadata).
    lastModifiedAt?: string;
    // ISO date-time when the database was last synchronized with its origin.
    lastSyncedAt?: string;
    // ISO date-time when the database was last replicated (replica side).
    lastReplicatedAt?: string;
    // Source id of the last item the automatic import backfill released, so a restart resumes there
    // rather than walking the whole photo library again. Device-local: it names a place in this
    // machine's photo source, which means nothing on another machine.
    autoImportBackfillCursor?: string;
    // True once the automatic import backfill has walked the whole photo library.
    autoImportBackfillCompleted?: boolean;
}

//
// Serializes the database state into the binary payload.
//
function serializeDatabaseState(state: IDatabaseState, serializer: ISerializer): void {
    serializer.writeBuffer(state.contentHash ?? Buffer.alloc(0));
    serializer.writeString(state.lastModifiedAt ?? "");
    serializer.writeString(state.lastSyncedAt ?? "");
    serializer.writeString(state.lastReplicatedAt ?? "");
    serializer.writeString(state.autoImportBackfillCursor ?? "");
    serializer.writeBoolean(state.autoImportBackfillCompleted ?? false);
}

//
// Deserializes the fields every version of the state file has.
// An empty buffer or empty string means the field is absent.
//
function deserializeCommonDatabaseState(deserializer: IDeserializer): IDatabaseState {
    const contentHash = deserializer.readBuffer();
    const lastModifiedAt = deserializer.readString();
    const lastSyncedAt = deserializer.readString();
    const lastReplicatedAt = deserializer.readString();

    const state: IDatabaseState = {};
    if (contentHash.length > 0) {
        state.contentHash = contentHash;
    }
    if (lastModifiedAt.length > 0) {
        state.lastModifiedAt = lastModifiedAt;
    }
    if (lastSyncedAt.length > 0) {
        state.lastSyncedAt = lastSyncedAt;
    }
    if (lastReplicatedAt.length > 0) {
        state.lastReplicatedAt = lastReplicatedAt;
    }
    return state;
}

//
// Deserializes a version 1 state file, which predates automatic import and so names no backfill.
//
function deserializeDatabaseStateV1(deserializer: IDeserializer): IDatabaseState {
    return deserializeCommonDatabaseState(deserializer);
}

//
// Deserializes a version 2 state file, which carries the automatic import backfill cursor.
//
function deserializeDatabaseStateV2(deserializer: IDeserializer): IDatabaseState {
    const state = deserializeCommonDatabaseState(deserializer);

    const autoImportBackfillCursor = deserializer.readString();
    if (autoImportBackfillCursor.length > 0) {
        state.autoImportBackfillCursor = autoImportBackfillCursor;
    }

    const autoImportBackfillCompleted = deserializer.readBoolean();
    if (autoImportBackfillCompleted) {
        state.autoImportBackfillCompleted = true;
    }

    return state;
}

//
// Loads the database state from .db/state.dat.
// Returns undefined if the file is missing, empty, truncated, or fails its checksum, so the caller
// rebuilds the state on the next write. Never throws for a bad file.
//
export async function loadDatabaseState(rawStorage: IStorage): Promise<IDatabaseState | undefined> {
    try {
        const state = await load<IDatabaseState>(
            rawStorage,
            STATE_PATH,
            STATE_TYPE_CODE,
            { 1: deserializeDatabaseStateV1, 2: deserializeDatabaseStateV2 },
            undefined,
            STATE_VERSION
        );
        return state ?? undefined;
    }
    catch {
        // Missing, zero-byte, or corrupt file: treat as absent so it is rebuilt.
        return undefined;
    }
}

//
// Saves the full database state to .db/state.dat.
// Lock-free primitive: the caller must already hold the database write lock (see acquireWriteLock).
//
export async function saveDatabaseState(rawStorage: IStorage, state: IDatabaseState): Promise<void> {
    await save(rawStorage, STATE_PATH, state, STATE_VERSION, STATE_TYPE_CODE, serializeDatabaseState);
}

//
// Merges partial into the existing state (or an empty state when absent) and saves it.
// Lock-free primitive: the caller must already hold the database write lock.
//
export async function mergeDatabaseState(rawStorage: IStorage, partial: Partial<IDatabaseState>): Promise<void> {
    const existing = await loadDatabaseState(rawStorage);
    const merged: IDatabaseState = { ...existing ?? {}, ...partial };
    await saveDatabaseState(rawStorage, merged);
}

//
// Merges partial into the state while holding the write lock for the duration.
// For callers that do not already hold the lock. Silently does nothing if the lock cannot be acquired.
//
export async function updateDatabaseStateLocked(rawStorage: IStorage, sessionId: string, partial: Partial<IDatabaseState>): Promise<void> {
    if (!await acquireWriteLock(rawStorage, sessionId)) {
        return;
    }
    try {
        await mergeDatabaseState(rawStorage, partial);
    }
    finally {
        await releaseWriteLock(rawStorage);
    }
}
