//
// Writes a config.yaml for the mobile smoke tests.
//
// A mobile test establishes the app's settings the way a desktop test writes a config file: before
// the app starts, from outside it. The app has no filesystem access of its own, so the harness
// renders the file here on the host and the platform helper copies it into the device's storage
// sandbox (android_seed_auto_import_config / android_seed_sync_config and their iOS counterparts).
//
// The rendering is buildConfigYaml in node-api, the same function the app writes the file through on
// device, so the harness and the app cannot drift on the format.
//
// Both features share one file, so a seed merges rather than replaces: seeding the syncing settings
// must not wipe what automatic import was told to watch. BASE names the device's current file, and
// every section MODE does not name is carried through from it unchanged.
//
// Usage:
//   MODE=auto-import ENABLED=true [DEFAULT_DATABASE_PATH=photosphere-default] [PAUSE_MS=5000] [ALBUM_ID=123] [BASE=<current-config>] bun write-config.ts <output-file>
//   MODE=sync ENABLED=true ONLY_ON_WIFI=false [PAUSE_MS=5000] [DATABASE_PATH=my-db] [BASE=<current-config>] bun write-config.ts <output-file>
//
// ALBUM_ID restricts the import to one album in the device photo library. Left unset, the settings
// name no places at all, which the app reads as the whole library: that is what a user gets before
// they choose albums, and what most mobile tests want on an emulator with nothing else on it. A test
// that runs against a real phone has to name an album, or every pass walks and imports somebody's
// entire photo collection.
//

import { readFileSync, writeFileSync } from "fs";
import { resolveAutoImportPauseMs } from "api/src/lib/auto-import-mobile";
import type { IAutoImportSource } from "api/src/lib/auto-import-settings";
import { resolveSyncPauseMs } from "api/src/lib/sync-settings";
import {
    buildConfigYaml,
    defaultConfigFile,
    parseConfigYamlChecked,
    sectionsPresent,
    type IConfigSectionsPresent,
    type IConfigFile,
} from "node-api/src/lib/config-format";

//
// The configuration read from BASE, and which of its sections were actually there.
//
interface IBaseConfig {
    // The configuration to start from.
    config: IConfigFile;

    // Which sections the base file carried.
    present: IConfigSectionsPresent;
}

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
// Reads an optional string environment variable, treating blank as unset.
//
function readOptionalString(variableName: string): string | undefined {
    const raw = process.env[variableName];
    return raw && raw.trim().length > 0 ? raw.trim() : undefined;
}

//
// The configuration the file starts from: the device's current one when BASE names a readable file,
// and the defaults otherwise.
//
// A BASE that names a file which is not there is the ordinary case, not an error: the first seed of
// a run happens on a device the app has never written settings on.
//
function baseConfig(): IBaseConfig {
    const absent: IBaseConfig = {
        config: defaultConfigFile(),
        present: sectionsPresent(undefined),
    };

    const basePath = readOptionalString("BASE");
    if (basePath === undefined) {
        return absent;
    }

    let text: string;
    try {
        text = readFileSync(basePath, "utf8");
    }
    catch (error: any) {
        if (error.code === "ENOENT") {
            return absent;
        }
        throw error;
    }

    const parsed = parseConfigYamlChecked(text);
    return {
        config: parsed.config,
        present: parsed.present,
    };
}

//
// Replaces the automatic import section, leaving every other section as it was.
//
function applyAutoImport(config: IConfigFile): void {
    const albumId = readOptionalString("ALBUM_ID");
    const sources: IAutoImportSource[] = albumId !== undefined
        ? [
            {
                type: "device-album",
                albumId,
            },
        ]
        : [];

    const rawPauseMs = readOptionalString("PAUSE_MS");
    config.autoImport = {
        settings: {
            enabled: readBoolean("ENABLED"),
            sources,
        },
        defaultDatabasePath: readOptionalString("DEFAULT_DATABASE_PATH"),
        pauseBetweenRunsMs: resolveAutoImportPauseMs(rawPauseMs ? Number(rawPauseMs) : undefined),
    };
}

//
// Replaces the syncing section, leaving every other section as it was.
//
function applySync(config: IConfigFile): void {
    const rawPauseMs = readOptionalString("PAUSE_MS");

    // The database to sync is optional here: a test that seeds one is saying the background loop has
    // something to push without waiting for the app to open a database and record it.
    config.sync = {
        settings: {
            enabled: readBoolean("ENABLED"),
            onlyOnWifi: readBoolean("ONLY_ON_WIFI"),
        },
        databasePath: readOptionalString("DATABASE_PATH"),
        pauseBetweenRunsMs: resolveSyncPauseMs(rawPauseMs ? Number(rawPauseMs) : undefined),
    };
}

//
// Renders the settings named by MODE and the environment into the file named by the last argument.
//
function main(): void {
    const outputPath = process.argv[process.argv.length - 1];
    if (!outputPath || outputPath.endsWith("write-config.ts")) {
        throw new Error("usage: MODE=<auto-import|sync> ... write-config.ts <output-file>");
    }

    const mode = process.env.MODE;
    const base = baseConfig();
    const present = base.present;

    if (mode === "auto-import") {
        applyAutoImport(base.config);
        present.autoImport = true;
    }
    else if (mode === "sync") {
        applySync(base.config);
        present.sync = true;
    }
    else {
        throw new Error(`MODE must be "auto-import" or "sync", got: ${mode ?? "(unset)"}`);
    }

    // Only the sections that have been set are written, which is exactly what the app's own write
    // handler does. A harness that wrote both would put a syncing section in the file the first time
    // a test seeded automatic import, and the app reads a section's presence as "these settings have
    // been chosen": it would then skip seeding a fresh install's syncing defaults, and the test would
    // be running against settings no user and no test ever asked for.
    writeFileSync(outputPath, buildConfigYaml(base.config, present));
}

main();
