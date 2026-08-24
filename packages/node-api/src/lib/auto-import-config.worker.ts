//
// Reads and writes auto-import.toml as a background task.
//
// The same arrangement as databases-config.worker.ts and for the same reason: the mobile WebView
// holds these settings but cannot open a file, so its reads and writes run in the embedded worker
// over the storage layer. Putting them in a file rather than in the WebView's localStorage is what
// lets a background import that runs while the app is off screen find out whether it is switched on
// at all, and what it should be watching.
//
// The file contents come from auto-import-config-format.ts, the same module every reader converts
// through, so a file written here is readable by anything else that opens it by construction.
//

import { parse as parseToml, stringify as stringifyToml } from "smol-toml";
import type { ITaskContext } from "task-queue";
import { log } from "utils";
import { FileStorage } from "storage";
import type { IAutoImportSettings } from "api/src/lib/auto-import-settings";
import { resolveAutoImportPauseMs, type IAutoImportFile } from "api/src/lib/auto-import-mobile";
import {
    autoImportFileToToml,
    tomlToAutoImportFile,
    type ITomlAutoImportConfig,
} from "./auto-import-config-format";

//
// Input for the read-auto-import-config task.
//
export interface IReadAutoImportConfigData {
    // Sandbox-relative path of auto-import.toml.
    configPath: string;
}

//
// Input for the write-auto-import-config task.
//
export interface IWriteAutoImportConfigData {
    // Sandbox-relative path of auto-import.toml.
    configPath: string;

    // The settings to write.
    settings: IAutoImportSettings;

    // The database automatic import writes to, or undefined when none has been chosen yet.
    defaultDatabasePath?: string;

    // The gap between background import passes, in milliseconds.
    pauseBetweenRunsMs: number;
}

//
// Result of the read-auto-import-config task.
//
export interface IReadAutoImportConfigResult {
    // The settings, filled from the defaults when the file does not exist or cannot be read.
    settings: IAutoImportSettings;

    // The database automatic import writes to, absent when none has been chosen yet.
    defaultDatabasePath?: string;

    // The gap between background import passes, in milliseconds.
    pauseBetweenRunsMs: number;
}

//
// Reads and converts the file at the given path, returning the defaults when it is not there.
//
// A file that will not parse also reads as the defaults rather than throwing. This one is written
// by the app and never shown to the user, so a corrupt copy is a bug somewhere else, and throwing
// here would take automatic import (and with it the settings card that could switch it off) down
// with it. The parse failure is logged so it is not silent.
//
export async function readAutoImportConfigFile(configPath: string): Promise<IAutoImportFile> {
    const storage = new FileStorage("fs:");
    if (!await storage.fileExists(configPath)) {
        return tomlToAutoImportFile(undefined);
    }

    const contents = await storage.read(configPath);
    if (!contents) {
        return tomlToAutoImportFile(undefined);
    }

    let toml: ITomlAutoImportConfig;
    try {
        toml = parseToml(contents.toString("utf8")) as ITomlAutoImportConfig;
    }
    catch (error) {
        log.error(`The automatic import settings at "${configPath}" could not be parsed, using the defaults: ${error}`);
        return tomlToAutoImportFile(undefined);
    }

    return tomlToAutoImportFile(toml);
}

//
// Handler for the read-auto-import-config task.
//
export async function readAutoImportConfigHandler(data: IReadAutoImportConfigData, _context: ITaskContext): Promise<IReadAutoImportConfigResult> {
    if (!data.configPath) {
        throw new Error("configPath is required");
    }

    const contents = await readAutoImportConfigFile(data.configPath);
    const result: IReadAutoImportConfigResult = {
        settings: contents.settings,
        pauseBetweenRunsMs: contents.pauseBetweenRunsMs,
    };
    if (contents.defaultDatabasePath !== undefined) {
        result.defaultDatabasePath = contents.defaultDatabasePath;
    }
    return result;
}

//
// Handler for the write-auto-import-config task.
//
export async function writeAutoImportConfigHandler(data: IWriteAutoImportConfigData, _context: ITaskContext): Promise<void> {
    if (!data.configPath) {
        throw new Error("configPath is required");
    }
    if (!data.settings) {
        throw new Error("settings is required");
    }

    const contents = buildAutoImportConfigToml({
        settings: data.settings,
        defaultDatabasePath: data.defaultDatabasePath,
        pauseBetweenRunsMs: resolveAutoImportPauseMs(data.pauseBetweenRunsMs),
    });
    const storage = new FileStorage("fs:");
    await storage.write(data.configPath, "application/toml", Buffer.from(contents, "utf8"));
}

//
// Renders the whole file as the TOML text of an auto-import.toml, returning it rather than writing
// it anywhere.
//
// Factored out of the write handler so a host-side script can produce a file the read handler reads
// back exactly, which is how a mobile smoke test establishes settings from outside the app.
//
export function buildAutoImportConfigToml(contents: IAutoImportFile): string {
    return stringifyToml(autoImportFileToToml(contents)) + "\n";
}
