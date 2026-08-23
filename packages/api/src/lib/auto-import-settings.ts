//
// Platform-neutral settings for automatic photo import.
//
// These are read by the auto-import task on every platform (CLI, desktop, mobile), so nothing in
// this file may depend on Node.js, Electron, Capacitor or the filesystem. The settings arrive from
// a config file that a user may have hand-edited, or that an older version of the app wrote, so
// `normaliseAutoImportSettings` is the only supported way to turn a stored blob into settings.
//

//
// A folder on the local filesystem that is watched for new media. Used by the CLI and the desktop
// app, where the operating system exposes photo locations as ordinary directories.
//
export interface IFolderAutoImportSource {
    // Discriminator identifying this as a folder source.
    type: "folder";

    // Absolute path of the folder to watch.
    path: string;

    // Whether subfolders of this folder are watched as well.
    recurse: boolean;
}

//
// An album in the device's photo library. Used by the mobile apps, where media is reached through
// MediaStore on Android and the Photos framework on iOS rather than through a filesystem path.
//
export interface IDeviceAlbumAutoImportSource {
    // Discriminator identifying this as a device album source.
    type: "device-album";

    // Platform-specific identifier of the album in the device photo library.
    albumId: string;
}

//
// The album identifier that means the whole photo library rather than one album in it.
//
// A device source has to name something, and "everything on this phone" is the default a user gets
// before they pick albums. Spelling it as a reserved id keeps the settings uniform: there is one
// kind of device source, not a source and a separate "watch everything" flag.
//
export const ALL_DEVICE_MEDIA_ALBUM_ID = "all";

//
// A place the auto-import task watches for new media.
//
export type IAutoImportSource = IFolderAutoImportSource | IDeviceAlbumAutoImportSource;

//
// The settings that control automatic photo import.
//
export interface IAutoImportSettings {
    // Whether automatic import runs at all. Everything else is ignored while this is off.
    enabled: boolean;

    // The places that are watched for new media.
    sources: IAutoImportSource[];

    // How many already-existing items the backfill lane is allowed to release per minute. The fast
    // lane, which carries items the watcher reported since the task started, is not paced by this.
    backfillItemsPerMinute: number;

}

//
// Auto-import off, and a backfill rate of 60 items per minute.
//
export const DEFAULT_AUTO_IMPORT_SETTINGS: IAutoImportSettings = {
    enabled: false,
    sources: [],
    backfillItemsPerMinute: 60,
};

//
// A source exactly as it was read from storage, before it has been checked. Every field is optional
// because nothing about a stored blob is guaranteed.
//
export interface IRawAutoImportSource {
    // The claimed source type. Anything other than "folder" or "device-album" is malformed.
    type?: string;

    // The folder path, for a folder source.
    path?: string;

    // Whether to recurse, for a folder source.
    recurse?: boolean;

    // The album identifier, for a device album source.
    albumId?: string;
}

//
// A settings blob exactly as it was read from storage, before it has been checked.
//
export interface IRawAutoImportSettings {
    // Whether automatic import is on.
    enabled?: boolean;

    // The places that are watched, each still unchecked.
    sources?: IRawAutoImportSource[];

    // The backfill pacing in items per minute.
    backfillItemsPerMinute?: number;

}

//
// True when the value is a boolean, so a stored string or number does not become a setting.
//
function isBoolean(value: boolean | undefined): boolean {
    return value === true || value === false;
}

//
// True when the value is a number that can actually be used for pacing: finite and greater than
// zero. A zero or negative rate would stall or reverse the backfill.
//
function isPositiveNumber(value: number | undefined): boolean {
    return typeof value === "number" && Number.isFinite(value) && value > 0;
}

//
// True when the value is a non-empty string.
//
function isNonEmptyString(value: string | undefined): boolean {
    return typeof value === "string" && value.length > 0;
}

//
// Turns one unchecked source into a usable source, or returns undefined when it is malformed and
// must be dropped.
//
export function normaliseAutoImportSource(rawSource: IRawAutoImportSource | null | undefined): IAutoImportSource | undefined {
    if (!rawSource) {
        return undefined;
    }

    if (rawSource.type === "folder") {
        if (!isNonEmptyString(rawSource.path)) {
            return undefined;
        }

        return {
            type: "folder",
            path: rawSource.path as string,
            recurse: isBoolean(rawSource.recurse) ? rawSource.recurse as boolean : true,
        };
    }

    if (rawSource.type === "device-album") {
        if (!isNonEmptyString(rawSource.albumId)) {
            return undefined;
        }

        return {
            type: "device-album",
            albumId: rawSource.albumId as string,
        };
    }

    return undefined;
}

//
// Fills missing fields from the defaults and drops malformed sources, so a hand-edited or older
// settings blob cannot crash the auto-import task.
//
export function normaliseAutoImportSettings(rawSettings: IRawAutoImportSettings | null | undefined): IAutoImportSettings {
    if (!rawSettings) {
        return { ...DEFAULT_AUTO_IMPORT_SETTINGS, sources: [] };
    }

    const rawSources = Array.isArray(rawSettings.sources) ? rawSettings.sources : [];
    const sources: IAutoImportSource[] = [];
    for (const rawSource of rawSources) {
        const source = normaliseAutoImportSource(rawSource);
        if (source) {
            sources.push(source);
        }
    }

    return {
        enabled: isBoolean(rawSettings.enabled) ? rawSettings.enabled as boolean : DEFAULT_AUTO_IMPORT_SETTINGS.enabled,
        sources,
        backfillItemsPerMinute: isPositiveNumber(rawSettings.backfillItemsPerMinute) ? rawSettings.backfillItemsPerMinute as number : DEFAULT_AUTO_IMPORT_SETTINGS.backfillItemsPerMinute,
    };
}
