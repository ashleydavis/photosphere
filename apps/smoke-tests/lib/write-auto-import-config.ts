//
// Writes an auto-import.toml for the mobile smoke tests.
//
// The counterpart of write-sync-config.ts, and for the same reason: a test that needs automatic
// import already switched on, writing into a database it seeded itself, has to say so before the app
// starts. Switching it on through the settings card instead makes the app create its own database,
// which is the right thing for the tests that are about that and no use to a test that needs the
// database to have an origin.
//
// The rendering is buildAutoImportConfigToml in node-api, the same function the app writes the file
// through on device, so the harness and the app cannot drift on the format.
//
// Usage: ENABLED=true [DEFAULT_DATABASE_PATH=photosphere-default] [PAUSE_MS=5000] [ALBUM_ID=123] bun write-auto-import-config.ts <output-file>
//
// ALBUM_ID restricts the import to one album in the device photo library. Left unset, the settings
// name no places at all, which the app reads as the whole library: that is what a user gets before
// they choose albums, and what most mobile tests want on an emulator with nothing else on it. A test
// that runs against a real phone has to name an album, or every pass walks and imports somebody's
// entire photo collection.
//

import { writeFileSync } from "fs";
import { resolveAutoImportPauseMs } from "api/src/lib/auto-import-mobile";
import type { IAutoImportSource } from "api/src/lib/auto-import-settings";
import { buildAutoImportConfigToml } from "node-api/src/lib/auto-import-config.worker";

//
// Reads a boolean environment variable, throwing when it holds anything but "true" or "false".
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
// Renders the settings from the ENABLED, DEFAULT_DATABASE_PATH and PAUSE_MS environment variables
// into the file named by the last argument.
//
function main(): void {
    const outputPath = process.argv[process.argv.length - 1];
    if (!outputPath || outputPath.endsWith("write-auto-import-config.ts")) {
        throw new Error("usage: ENABLED=<bool> [DEFAULT_DATABASE_PATH=<path>] [PAUSE_MS=<ms>] write-auto-import-config.ts <output-file>");
    }

    const rawDefaultDatabasePath = process.env.DEFAULT_DATABASE_PATH;
    const defaultDatabasePath = rawDefaultDatabasePath && rawDefaultDatabasePath.trim().length > 0
        ? rawDefaultDatabasePath
        : undefined;

    const rawPauseMs = process.env.PAUSE_MS;
    const pauseBetweenRunsMs = resolveAutoImportPauseMs(rawPauseMs ? Number(rawPauseMs) : undefined);

    const rawAlbumId = process.env.ALBUM_ID;
    const sources: IAutoImportSource[] = rawAlbumId && rawAlbumId.trim().length > 0
        ? [
            {
                type: "device-album",
                albumId: rawAlbumId.trim(),
            },
        ]
        : [];

    writeFileSync(outputPath, buildAutoImportConfigToml({
        settings: {
            enabled: readBoolean("ENABLED"),
            sources,
        },
        defaultDatabasePath,
        pauseBetweenRunsMs,
    }));
}

main();
