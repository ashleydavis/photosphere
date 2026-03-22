//
// Database config stored at .db/config.json.
// Created on init/upgrade; holds origin, lastReplicatedAt, lastSyncedAt, lastModifiedAt.
//

import { IStorage } from "storage";
import { retry } from "utils";

const CONFIG_PATH = ".db/config.json";

export interface IDatabaseConfig {
    /** Path or URI of the database this copy was replicated from. */
    origin?: string;
    /** ISO date-time when the database was last replicated (replica side). */
    lastReplicatedAt?: string;
    /** ISO date-time when the database was last synchronized. */
    lastSyncedAt?: string;
    /** ISO date-time when the database was last modified locally (add, remove, edit metadata). */
    lastModifiedAt?: string;
}

//
// Loads the database config from .db/config.json. Returns null if the file does not exist.
//
export async function loadDatabaseConfig(assetStorage: IStorage): Promise<IDatabaseConfig | null> {
    if (!await assetStorage.fileExists(CONFIG_PATH)) {
        return null;
    }
    const data = await retry(() => assetStorage.read(CONFIG_PATH));  //todo: need to use raw storage
    if (!data) {
        return null;
    }
    const text = data.toString("utf8");
    const parsed = JSON.parse(text) as IDatabaseConfig;
    return parsed;
}

//
// Saves the full database config to .db/config.json.
//
export async function saveDatabaseConfig(assetStorage: IStorage, config: IDatabaseConfig): Promise<void> {
    const text = JSON.stringify(config, null, 2);
    await retry(() => assetStorage.write(CONFIG_PATH, "application/json", Buffer.from(text, "utf8"))); //todo: need to use raw storage
}

//
// Updates the database config by merging partial into the existing config (or empty object).
//
export async function updateDatabaseConfig(
    assetStorage: IStorage,
    partial: Partial<IDatabaseConfig>
): Promise<void> {
    const existing = await loadDatabaseConfig(assetStorage);
    const merged: IDatabaseConfig = { ...existing ?? {}, ...partial };
    await saveDatabaseConfig(assetStorage, merged);
}
