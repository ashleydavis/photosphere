//
// Writes a sync.toml for the mobile smoke tests.
//
// A mobile test establishes the two syncing settings the way a desktop test writes a config file:
// before the app starts, from outside it. The app has no filesystem access of its own, so the
// harness renders the file here on the host and the platform helper copies it into the device's
// storage sandbox (android_seed_sync_config / ios_seed_sync_config).
//
// The rendering is buildSyncConfigToml in node-api, the same function the app writes the file
// through on device, so the harness and the app cannot drift on the format.
//
// Usage: ENABLED=true ONLY_ON_WIFI=false [PAUSE_MS=5000] [DATABASE_PATH=my-db] bun write-sync-config.ts <output-file>
//

import { writeFileSync } from "fs";
import { resolveSyncPauseMs } from "api/src/lib/sync-settings";
import { buildSyncConfigToml } from "node-api/src/lib/sync-config.worker";

//
// Reads a boolean environment variable, throwing when it holds anything but "true" or "false".
//
// A test that meant to switch syncing off and silently switched it on would pass or fail for reasons
// that have nothing to do with what it is testing, so anything unrecognised is refused here.
//
function readBoolean(variableName: string): boolean {
    const raw = process.env[variableName];
    if (raw === "true") {
        return true;
    }
    if (raw === "false") {
        return false;
    }
    throw new Error(`${variableName} must be "true" or "false", got: ${raw ?? "(unset)"}`);
}

//
// Renders the settings from the ENABLED, ONLY_ON_WIFI and PAUSE_MS environment variables into the
// file named by the last argument.
//
function main(): void {
    const outputPath = process.argv[process.argv.length - 1];
    if (!outputPath || outputPath.endsWith("write-sync-config.ts")) {
        throw new Error("usage: ENABLED=<bool> ONLY_ON_WIFI=<bool> [PAUSE_MS=<ms>] write-sync-config.ts <output-file>");
    }

    const rawPauseMs = process.env.PAUSE_MS;
    const pauseBetweenRunsMs = resolveSyncPauseMs(rawPauseMs ? Number(rawPauseMs) : undefined);

    // The database to sync is optional here: a test that seeds one is saying the background loop has
    // something to push without waiting for the app to open a database and record it.
    const rawDatabasePath = process.env.DATABASE_PATH;
    const databasePath = rawDatabasePath && rawDatabasePath.trim().length > 0 ? rawDatabasePath : undefined;

    writeFileSync(outputPath, buildSyncConfigToml({
        settings: {
            enabled: readBoolean("ENABLED"),
            onlyOnWifi: readBoolean("ONLY_ON_WIFI"),
        },
        databasePath,
        pauseBetweenRunsMs,
    }));
}

main();
