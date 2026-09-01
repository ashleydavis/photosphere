//
// Platform-neutral settings for automatic syncing.
//
// These are read by the app's interface and by the mobile background sync loop, so nothing in this
// file may depend on Node.js, Electron, Capacitor or the filesystem. The values arrive from a config
// file that a user may have hand-edited, or that an older version of the app wrote, so
// `normaliseSyncSettings` is the only supported way to turn a stored blob into settings.
//

//
// The settings that control automatic syncing.
//
export interface ISyncSettings {
    // Whether automatic syncing runs at all. The master switch: everything else is ignored while
    // this is off.
    enabled: boolean;

    // Whether automatic syncing is refused while the connection is cellular.
    onlyOnWifi: boolean;
}

//
// The settings a reader falls back to when it has nothing it can believe.
//
// Syncing off, deliberately. A file that is missing or will not parse is not a user saying "sync
// over anything you like": the app writes this file, so a copy nobody can read means something is
// wrong, and the safe answer to "should this phone start pushing photos over its cellular
// connection?" is no. The interface seeds the file with its own defaults the first time it runs,
// which is what stops a fresh install sitting here.
//
export const DEFAULT_SYNC_SETTINGS: ISyncSettings = {
    enabled: false,
    onlyOnWifi: true,
};

//
// The settings a fresh installation starts from.
//
// Syncing on and restricted to Wi-Fi, which is what the two toggles show before anyone touches
// them. Separate from DEFAULT_SYNC_SETTINGS above because they answer different questions: this one
// is what a new user should get, that one is what to do when a file cannot be read.
//
export const INITIAL_SYNC_SETTINGS: ISyncSettings = {
    enabled: true,
    onlyOnWifi: true,
};

//
// The stored form of the settings, as read from a file or a config store.
//
// Every field is optional and of unknown quality: this is what a hand-edited or older file may
// hold, before anything has checked it.
//
export interface IRawSyncSettings {
    // Whether automatic syncing runs at all.
    enabled?: boolean;

    // Whether automatic syncing is refused on a cellular connection.
    onlyOnWifi?: boolean;
}

//
// Turns a stored blob into settings, filling anything missing or malformed from the defaults.
//
// A value that is not a boolean falls back rather than being coerced, because a string "false" read
// from a hand-edited file is truthy and would switch syncing on for somebody who wrote the opposite.
//
export function normaliseSyncSettings(stored: IRawSyncSettings | undefined): ISyncSettings {
    if (!stored) {
        return { ...DEFAULT_SYNC_SETTINGS };
    }

    return {
        enabled: typeof stored.enabled === "boolean" ? stored.enabled : DEFAULT_SYNC_SETTINGS.enabled,
        onlyOnWifi: typeof stored.onlyOnWifi === "boolean" ? stored.onlyOnWifi : DEFAULT_SYNC_SETTINGS.onlyOnWifi,
    };
}

//
// Everything the mobile sync settings file holds.
//
// The settings themselves and the pacing of the background loop. The database that is synced is not
// here: it is the one automatic import writes to, recorded in auto-import.toml, and a fact recorded
// in two files is a fact that goes out of step.
//
export interface ISyncFile {
    // The settings automatic syncing runs with.
    settings: ISyncSettings;

    // The gap between background sync passes, in milliseconds. Already resolved, so a file asking
    // for zero or a negative gap comes back holding the default.
    pauseBetweenRunsMs: number;
}

//
// How long the background sync waits between passes when the settings file does not say.
//
// The same five minutes the desktop's periodic sync uses, and what the mobile WebView scheduler used
// before the loop moved to the native side. A pass where nothing has changed still costs a small
// read at the origin, which on a phone is a network request and a little battery, so the gap is what
// keeps an idle phone from paying for that every few seconds.
//
export const DEFAULT_SYNC_PAUSE_MS = 5 * 60 * 1000;

//
// The gap between background sync passes, in milliseconds.
//
// Zero, a negative number, and anything that is not a finite number all fall back to the default.
// The value is read from a file a user may edit, and a gap of zero is a loop that starts a fresh
// pass the instant the last one ends, which on a phone is a flat battery rather than a fast backup.
//
export function resolveSyncPauseMs(pauseMs: number | undefined): number {
    if (typeof pauseMs !== "number" || !Number.isFinite(pauseMs) || pauseMs <= 0) {
        return DEFAULT_SYNC_PAUSE_MS;
    }
    return pauseMs;
}
