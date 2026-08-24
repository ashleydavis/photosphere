//
// The on-disk contents of auto-import.toml and the conversions between it and the in-memory types.
//
// The automatic import settings used to live in the mobile WebView's localStorage, which nothing
// outside the WebView can read. A background import that runs while the app is not on screen has to
// find out whether it is switched on and what it should be watching, so the settings live in a file
// in the app's storage sandbox instead, beside databases.toml.
//
// Nothing here touches the filesystem, which is what lets it be bundled into the mobile worker, and
// it is the only definition of the file format, so the reader and the writer cannot drift apart.
//

import {
    IAutoImportSource,
    IRawAutoImportSettings,
    IRawAutoImportSource,
    normaliseAutoImportSettings,
} from "api/src/lib/auto-import-settings";
import { resolveAutoImportPauseMs, type IAutoImportFile } from "api/src/lib/auto-import-mobile";

//
// TOML on-disk contents for a single watched place (snake_case keys).
//
export interface ITomlAutoImportSource {
    // The kind of place: "folder" or "device-album".
    type?: string;

    // The folder path, for a folder source.
    path?: string;

    // Whether subfolders are watched, for a folder source.
    recurse?: boolean;

    // The album identifier, for a device album source.
    album_id?: string;
}

//
// TOML on-disk contents for auto-import.toml (snake_case keys).
//
export interface ITomlAutoImportConfig {
    // Whether automatic import runs at all.
    enabled?: boolean;

    // How many already-existing items the backfill lane may release per minute.
    backfill_items_per_minute?: number;

    // The sandbox-relative path of the database automatic import writes to.
    default_database_path?: string;

    // The gap between background import passes, in milliseconds. Absent in a file the app wrote:
    // the default applies unless someone has put a value here.
    pause_between_runs_ms?: number;

    // The places that are watched for new media.
    sources?: ITomlAutoImportSource[];
}

//
// Converts one TOML-shaped source to the raw source the normaliser checks.
//
// It goes to the raw type rather than straight to IAutoImportSource because a hand-edited or older
// file may hold anything at all, and normaliseAutoImportSettings is the only supported way to turn
// that into settings.
//
function tomlSourceToRawSource(tomlSource: ITomlAutoImportSource): IRawAutoImportSource {
    return {
        type: tomlSource.type,
        path: tomlSource.path,
        recurse: tomlSource.recurse,
        albumId: tomlSource.album_id,
    };
}

//
// Converts one watched place to its TOML on-disk contents, writing only the fields its kind uses.
//
function sourceToToml(source: IAutoImportSource): ITomlAutoImportSource {
    if (source.type === "folder") {
        return {
            type: "folder",
            path: source.path,
            recurse: source.recurse,
        };
    }

    return {
        type: "device-album",
        album_id: source.albumId,
    };
}

//
// Turns the parsed TOML into the settings and the default database path.
//
// Anything missing or malformed comes back as the default, because a settings file the user never
// sees must not be able to stop automatic import (or the app) from starting.
//
export function tomlToAutoImportFile(toml: ITomlAutoImportConfig | undefined): IAutoImportFile {
    if (!toml) {
        return {
            settings: normaliseAutoImportSettings(undefined),
            defaultDatabasePath: undefined,
            pauseBetweenRunsMs: resolveAutoImportPauseMs(undefined),
        };
    }

    const rawSources = Array.isArray(toml.sources) ? toml.sources.map(tomlSourceToRawSource) : [];
    const rawSettings: IRawAutoImportSettings = {
        enabled: toml.enabled,
        sources: rawSources,
        backfillItemsPerMinute: toml.backfill_items_per_minute,
    };

    const defaultDatabasePath = typeof toml.default_database_path === "string" && toml.default_database_path.length > 0
        ? toml.default_database_path
        : undefined;

    return {
        settings: normaliseAutoImportSettings(rawSettings),
        defaultDatabasePath,
        pauseBetweenRunsMs: resolveAutoImportPauseMs(toml.pause_between_runs_ms),
    };
}

//
// Turns the settings and the default database path into the TOML on-disk contents.
//
export function autoImportFileToToml(contents: IAutoImportFile): ITomlAutoImportConfig {
    const toml: ITomlAutoImportConfig = {
        enabled: contents.settings.enabled,
        backfill_items_per_minute: contents.settings.backfillItemsPerMinute,
        pause_between_runs_ms: contents.pauseBetweenRunsMs,
        sources: contents.settings.sources.map(sourceToToml),
    };

    if (contents.defaultDatabasePath !== undefined) {
        toml.default_database_path = contents.defaultDatabasePath;
    }

    return toml;
}
