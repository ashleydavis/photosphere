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
const STATE_VERSION = 1;

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
}

//
// Serializes the database state into the binary payload.
//
function serializeDatabaseState(state: IDatabaseState, serializer: ISerializer): void {
    serializer.writeBuffer(state.contentHash ?? Buffer.alloc(0));
    serializer.writeString(state.lastModifiedAt ?? "");
    serializer.writeString(state.lastSyncedAt ?? "");
    serializer.writeString(state.lastReplicatedAt ?? "");
}

//
// Deserializes the database state from the binary payload.
// An empty buffer or empty string means the field is absent.
//
function deserializeDatabaseState(deserializer: IDeserializer): IDatabaseState {
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
            { [STATE_VERSION]: deserializeDatabaseState },
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
