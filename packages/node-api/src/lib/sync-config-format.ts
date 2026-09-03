//
// The on-disk contents of sync.toml and the conversions between it and the in-memory types.
//
// The two syncing settings used to live in the mobile WebView's config store, which nothing outside
// the WebView can read. The background sync loop runs while the app is not on screen and has to find
// out whether syncing is switched on and whether it is restricted to Wi-Fi, so the settings live in
// a file in the app's storage sandbox instead, beside databases.toml and auto-import.toml.
//
// Nothing here touches the filesystem, which is what lets it be bundled into the mobile worker, and
// it is the only definition of the file format, so the reader and the writer cannot drift apart.
//

import {
    normaliseSyncSettings,
    resolveSyncPauseMs,
    type IRawSyncSettings,
    type ISyncFile,
} from "api/src/lib/sync-settings";

//
// TOML on-disk contents for sync.toml (snake_case keys).
//
export interface ITomlSyncConfig {
    // Whether automatic syncing runs at all.
    enabled?: boolean;

    // Whether automatic syncing is refused on a cellular connection.
    only_on_wifi?: boolean;

    // The sandbox-relative path of the database the background sync pushes.
    database_path?: string;

    // The gap between background sync passes, in milliseconds. Absent in a file the app wrote: the
    // default applies unless someone has put a value here.
    pause_between_runs_ms?: number;
}

//
// Turns the parsed TOML into the settings and the pacing.
//
// A file that is not there arrives here as undefined and comes back as the defaults, which have
// syncing switched off. That is the whole point of the defaults being what they are: a phone that
// cannot read its settings must not start pushing over a metered connection.
//
export function tomlToSyncFile(toml: ITomlSyncConfig | undefined): ISyncFile {
    if (!toml) {
        return {
            settings: normaliseSyncSettings(undefined),
            databasePath: undefined,
            pauseBetweenRunsMs: resolveSyncPauseMs(undefined),
        };
    }

    const rawSettings: IRawSyncSettings = {
        enabled: toml.enabled,
        onlyOnWifi: toml.only_on_wifi,
    };

    const databasePath = typeof toml.database_path === "string" && toml.database_path.length > 0
        ? toml.database_path
        : undefined;

    return {
        settings: normaliseSyncSettings(rawSettings),
        databasePath,
        pauseBetweenRunsMs: resolveSyncPauseMs(toml.pause_between_runs_ms),
    };
}

//
// Turns the settings and the pacing into the TOML on-disk contents.
//
export function syncFileToToml(contents: ISyncFile): ITomlSyncConfig {
    const toml: ITomlSyncConfig = {
        enabled: contents.settings.enabled,
        only_on_wifi: contents.settings.onlyOnWifi,
        pause_between_runs_ms: contents.pauseBetweenRunsMs,
    };

    if (contents.databasePath !== undefined) {
        toml.database_path = contents.databasePath;
    }

    return toml;
}
