//
// The on-disk contents of config.yaml and the conversions between it and the in-memory type.
//
// One file holds every setting the app remembers, on every platform: ~/.config/photosphere/config.yaml
// for the CLI and the desktop app, and config.yaml at the root of the storage sandbox on a phone. One
// file means one format definition, so a setting means the same thing whichever platform wrote it.
// The wiki page "Configuration-File" documents the file for users.
//
// Nothing here touches the filesystem, which is what lets it be bundled into the mobile worker, and
// it is the only definition of the file format, so the reader and the writer cannot drift apart.
//
// This file is what the user chose. What the app remembered on its own, so the interface comes back
// the way it was left, is in state.yaml beside it (see state-format.ts). The two are split because
// only one of them is worth documenting, hand-editing or carrying to another machine.
//
// The settings themselves are not defined here. The normalisers in `api` own what a valid setting is
// (normaliseSyncSettings, normaliseAutoImportSettings and the two pause resolvers), because the
// interface applies the same rules to values that never came from this file. This module is only
// about the document: which section a setting sits in, and what its key is called on disk.
//

import yaml from "js-yaml";
import {
    IAutoImportSource,
    IRawAutoImportSettings,
    IRawAutoImportSource,
    normaliseAutoImportSettings,
} from "api/src/lib/auto-import-settings";
import { resolveAutoImportPauseMs, type IAutoImportFile } from "api/src/lib/auto-import-mobile";
import {
    normaliseSyncSettings,
    resolveSyncPauseMs,
    type IRawSyncSettings,
    type ISyncFile,
} from "api/src/lib/sync-settings";

//
// The theme the interface runs with. "system" follows the operating system.
//
export type IConfigTheme = 'light' | 'dark' | 'system';

//
// Everything config.yaml holds, in memory, with camelCase fields.
//
// The auto-import and sync sections are the already-resolved types the rest of the app works with
// (settings plus pacing plus the database path), not raw stored blobs: anything reading this type
// has values that have been through the normalisers.
//
export interface IConfigFile {
    //
    // Which theme the interface uses.
    //
    theme?: IConfigTheme;

    //
    // Whether developer mode is on, which reveals the developer tools in the interface.
    //
    developerMode?: boolean;

    //
    // Whether the frames-per-second overlay is drawn.
    //
    showFpsIndicator?: boolean;

    //
    // The searches the user has deliberately saved from the sidebar. The ones they merely ran are in
    // state.yaml, because those the app remembered rather than the user chose.
    //
    savedSearches?: string[];

    //
    // What automatic photo import watches, where it puts what it finds, and how often it looks.
    //
    autoImport: IAutoImportFile;

    //
    // Whether the source file is deleted once the photo is confirmed in the database.
    //
    autoImportCleanupEnabled?: boolean;

    //
    // The two syncing toggles, the database the background loop pushes, and how often it runs.
    //
    sync: ISyncFile;
}

//
// On-disk contents of one watched place (snake_case keys).
//
export interface IYamlAutoImportSource {
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
// On-disk contents of the `auto_import` section.
//
export interface IYamlAutoImportSection {
    // Whether automatic import runs at all.
    enabled?: boolean;

    // The path of the database automatic import writes to. Relative to the storage sandbox on mobile.
    default_database_path?: string;

    // The gap between background import passes, in milliseconds.
    pause_between_runs_ms?: number;

    // Whether the source file is deleted once the photo is confirmed in the database.
    cleanup_enabled?: boolean;

    // The places that are watched for new media.
    sources?: IYamlAutoImportSource[];
}

//
// On-disk contents of the `sync` section.
//
export interface IYamlSyncSection {
    // Whether automatic syncing runs at all.
    enabled?: boolean;

    // Whether automatic syncing is refused on a cellular connection.
    only_on_wifi?: boolean;

    // The path of the database the background sync pushes.
    database_path?: string;

    // The gap between background sync passes, in milliseconds.
    pause_between_runs_ms?: number;
}

//
// The whole on-disk document (snake_case keys, sections nested by feature).
//
export interface IYamlConfigFile {
    // Which theme the interface uses.
    theme?: IConfigTheme;

    // Whether developer mode is on.
    developer_mode?: boolean;

    // Whether the frames-per-second overlay is drawn.
    show_fps_indicator?: boolean;

    // The searches the user has deliberately saved.
    saved_searches?: string[];

    // Automatic photo import.
    auto_import?: IYamlAutoImportSection;

    // Automatic syncing.
    sync?: IYamlSyncSection;
}

//
// The themes a config file is allowed to name. A file that says anything else is ignored rather
// than passed through, because the value reaches the interface and picking a stylesheet by a name
// nobody defined leaves a window with no styling at all.
//
export const ALLOWED_THEMES: IConfigTheme[] = ['light', 'dark', 'system'];

//
// Converts one on-disk source to the raw source the normaliser checks.
//
// It goes to the raw type rather than straight to IAutoImportSource because a hand-edited or older
// file may hold anything at all, and normaliseAutoImportSettings is the only supported way to turn
// that into settings.
//
function yamlSourceToRawSource(yamlSource: IYamlAutoImportSource): IRawAutoImportSource {
    return {
        type: yamlSource.type,
        path: yamlSource.path,
        recurse: yamlSource.recurse,
        albumId: yamlSource.album_id,
    };
}

//
// Converts one watched place to its on-disk contents, writing only the fields its kind uses.
//
function sourceToYaml(source: IAutoImportSource): IYamlAutoImportSource {
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
// True when the value is an object we can read keys off, and not an array or null.
//
// Every section is read through this because a hand-edited file can put a string or a list where a
// section belongs, and reading keys off one of those gives undefined for everything, which would
// silently look like an empty section rather than a malformed one.
//
function isSection(value: any): boolean {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

//
// Turns the `auto_import` section into the settings, the database path and the pacing.
//
function yamlToAutoImportFile(section: IYamlAutoImportSection | undefined): IAutoImportFile {
    if (!isSection(section)) {
        return {
            settings: normaliseAutoImportSettings(undefined),
            defaultDatabasePath: undefined,
            pauseBetweenRunsMs: resolveAutoImportPauseMs(undefined),
        };
    }

    const rawSources = Array.isArray(section!.sources) ? section!.sources.map(yamlSourceToRawSource) : [];
    const rawSettings: IRawAutoImportSettings = {
        enabled: section!.enabled,
        sources: rawSources,
    };

    const defaultDatabasePath = typeof section!.default_database_path === "string" && section!.default_database_path.length > 0
        ? section!.default_database_path
        : undefined;

    return {
        settings: normaliseAutoImportSettings(rawSettings),
        defaultDatabasePath,
        pauseBetweenRunsMs: resolveAutoImportPauseMs(section!.pause_between_runs_ms),
    };
}

//
// Turns the `sync` section into the settings, the database path and the pacing.
//
function yamlToSyncFile(section: IYamlSyncSection | undefined): ISyncFile {
    if (!isSection(section)) {
        return {
            settings: normaliseSyncSettings(undefined),
            databasePath: undefined,
            pauseBetweenRunsMs: resolveSyncPauseMs(undefined),
        };
    }

    const rawSettings: IRawSyncSettings = {
        enabled: section!.enabled,
        onlyOnWifi: section!.only_on_wifi,
    };

    const databasePath = typeof section!.database_path === "string" && section!.database_path.length > 0
        ? section!.database_path
        : undefined;

    return {
        settings: normaliseSyncSettings(rawSettings),
        databasePath,
        pauseBetweenRunsMs: resolveSyncPauseMs(section!.pause_between_runs_ms),
    };
}

//
// Turns the parsed document into the configuration the app works with.
//
// A file that is not there arrives here as undefined and comes back as the defaults, which have both
// automatic import and syncing switched off. That is the whole point of the defaults being what they
// are: a phone that cannot read its settings must not start pushing over a metered connection.
//
// A section that is malformed falls back to that section's own defaults without discarding the
// sections that did parse, and a key nothing recognises is ignored rather than rejected. One
// mistyped line in a hand-edited file must not cost the user every other setting in it.
//
export function yamlToConfigFile(document: IYamlConfigFile | undefined): IConfigFile {
    const parsed: IYamlConfigFile = isSection(document) ? document! : {};

    const config: IConfigFile = {
        autoImport: yamlToAutoImportFile(parsed.auto_import),
        sync: yamlToSyncFile(parsed.sync),
    };

    if (typeof parsed.theme === "string" && ALLOWED_THEMES.includes(parsed.theme)) {
        config.theme = parsed.theme;
    }
    if (typeof parsed.developer_mode === "boolean") {
        config.developerMode = parsed.developer_mode;
    }
    if (typeof parsed.show_fps_indicator === "boolean") {
        config.showFpsIndicator = parsed.show_fps_indicator;
    }
    if (Array.isArray(parsed.saved_searches)) {
        config.savedSearches = parsed.saved_searches.filter(search => typeof search === "string");
    }
    if (isSection(parsed.auto_import) && typeof parsed.auto_import!.cleanup_enabled === "boolean") {
        config.autoImportCleanupEnabled = parsed.auto_import!.cleanup_enabled;
    }

    return config;
}

//
// Turns the configuration into the document written to disk.
//
// An absent optional field stays absent rather than being written as null, so a file the app wrote
// holds only settings that have actually been chosen, and a reader cannot tell "never set" from
// "explicitly set to nothing" wrongly. An empty sources list is the exception and is written as an
// empty list, because "watching nothing" is a state a user can choose and is not the same as never
// having touched automatic import.
//
export function configFileToYaml(config: IConfigFile, emit?: IConfigSectionsPresent): IYamlConfigFile {
    const autoImport: IYamlAutoImportSection = {
        enabled: config.autoImport.settings.enabled,
        pause_between_runs_ms: config.autoImport.pauseBetweenRunsMs,
        sources: config.autoImport.settings.sources.map(sourceToYaml),
    };
    if (config.autoImport.defaultDatabasePath !== undefined) {
        autoImport.default_database_path = config.autoImport.defaultDatabasePath;
    }
    if (config.autoImportCleanupEnabled !== undefined) {
        autoImport.cleanup_enabled = config.autoImportCleanupEnabled;
    }

    const sync: IYamlSyncSection = {
        enabled: config.sync.settings.enabled,
        only_on_wifi: config.sync.settings.onlyOnWifi,
        pause_between_runs_ms: config.sync.pauseBetweenRunsMs,
    };
    if (config.sync.databasePath !== undefined) {
        sync.database_path = config.sync.databasePath;
    }

    const document: IYamlConfigFile = {};

    if (config.theme !== undefined) {
        document.theme = config.theme;
    }
    if (config.developerMode !== undefined) {
        document.developer_mode = config.developerMode;
    }
    if (config.showFpsIndicator !== undefined) {
        document.show_fps_indicator = config.showFpsIndicator;
    }
    if (config.savedSearches !== undefined) {
        document.saved_searches = config.savedSearches;
    }

    // A section is written only once its feature has actually been set, so a reader can tell "nobody
    // has chosen this" from "somebody switched it off". Writing every section every time would put an
    // `auto_import` section in the file the moment syncing was switched on, and a fresh install would
    // then be told automatic import had already been decided.
    if (emit === undefined || emit.autoImport) {
        document.auto_import = autoImport;
    }
    if (emit === undefined || emit.sync) {
        document.sync = sync;
    }

    return document;
}

//
// The configuration a reader falls back to when there is no file, used wherever a caller needs the
// defaults without having a document to convert.
//
export function defaultConfigFile(): IConfigFile {
    return yamlToConfigFile(undefined);
}

//
// Which sections a document actually carried.
//
// Separate from the configuration itself, which fills every section from the defaults so nothing
// downstream has to check. A caller sometimes has to tell "nobody has written this yet" from
// "somebody switched it off", and the settings alone cannot say which it is because both read as
// switched off. When the sections lived in files of their own the file's existence answered that;
// with one file it does not, because automatic import writing its section brings the file into being
// for syncing as well.
//
export interface IConfigSectionsPresent {
    //
    // Whether the document carried an `auto_import` section.
    //
    autoImport: boolean;

    //
    // Whether the document carried a `sync` section.
    //
    sync: boolean;
}

//
// Reports which sections a parsed document carried.
//
export function sectionsPresent(document: IYamlConfigFile | undefined): IConfigSectionsPresent {
    if (!isSection(document)) {
        return {
            autoImport: false,
            sync: false,
        };
    }

    return {
        autoImport: isSection(document!.auto_import),
        sync: isSection(document!.sync),
    };
}

//
// The result of parsing a config file: the configuration, and whether the text was readable at all.
//
export interface IParsedConfigFile {
    //
    // The configuration. The defaults when the text could not be parsed.
    //
    config: IConfigFile;

    //
    // True when the text is not valid YAML, so `config` is the defaults rather than anything the
    // file asked for. The caller reports it: a corrupt settings file is a bug somewhere else, and a
    // reader that quietly substituted the defaults would hide it.
    //
    malformed: boolean;

    //
    // What the YAML parser said, when it refused the text. Absent otherwise.
    //
    parseError?: string;

    //
    // Which sections the document actually carried. Both false for text that would not parse.
    //
    present: IConfigSectionsPresent;

    //
    // The document as it was parsed, before any section was filled in from the defaults. Undefined
    // for an empty file and for text that would not parse.
    //
    // A caller that writes one setting by the name the interface uses needs this rather than the
    // configuration: the flat view has to be able to tell a setting nobody has chosen from one that
    // was switched off, and the configuration has already lost that distinction.
    //
    document?: IYamlConfigFile;
}

//
// Parses the text of a config file, reporting whether it was readable.
//
// Text that will not parse as YAML comes back as the defaults rather than throwing, for the same
// reason an absent file does: this runs on a phone whose only copy of the file may have been
// hand-edited, and refusing to start is a worse answer than starting with syncing switched off. The
// caller is told, so the failure reaches the log instead of being silent.
//
export function parseConfigYamlChecked(text: string): IParsedConfigFile {
    let document: IYamlConfigFile | null | undefined;
    try {
        document = yaml.load(text) as IYamlConfigFile | null | undefined;
    }
    catch (error) {
        return {
            config: defaultConfigFile(),
            malformed: true,
            parseError: `${error}`,
            present: sectionsPresent(undefined),
        };
    }

    const parsed = document === null ? undefined : document;
    return {
        config: yamlToConfigFile(parsed),
        malformed: false,
        present: sectionsPresent(parsed),
        document: isSection(parsed) ? parsed : undefined,
    };
}

//
// Parses the text of a config file into the configuration, for a caller with nothing useful to do
// about text that will not parse.
//
export function parseConfigYaml(text: string): IConfigFile {
    return parseConfigYamlChecked(text).config;
}

//
// Renders the configuration as the text of a config file.
//
export function buildConfigYaml(config: IConfigFile, emit?: IConfigSectionsPresent): string {
    return yaml.dump(configFileToYaml(config, emit));
}
