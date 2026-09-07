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
// What the notification system has already shown on this install, so it does not show it twice.
//
// State rather than a setting, and in this file rather than one of its own because the config
// directory holding one file is the point of the merge. Shared between the desktop app and the CLI
// on the same machine: an item announced by one is not announced again by the other.
//
export interface INewsConfig {
    //
    // Stable ids of news items that have already been shown to the user, in the order they were
    // first seen.
    //
    shownNewsIds: string[];

    //
    // The release version the user has already been told about. A newer release on GitHub notifies
    // again and overwrites this.
    //
    lastShownUpdateVersion?: string;
}

//
// Preferences that only mean something where there is a window and a file dialog.
//
export interface IDesktopSection {
    //
    // The folder the file dialog reopens at.
    //
    lastFolder?: string;

    //
    // The folder the download dialog reopens at.
    //
    lastDownloadFolder?: string;

    //
    // Recently executed searches, most recent first, capped at MAX_RECENT_SEARCHES.
    //
    recentSearches?: string[];

    //
    // Whether the frames-per-second overlay is drawn.
    //
    showFpsIndicator?: boolean;

    //
    // Whether the native inspector was open when the app closed, so it can be reopened on startup.
    //
    devToolsOpen?: boolean;
}

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

    //
    // Preferences that only apply where there is a window.
    //
    desktop: IDesktopSection;

    //
    // What the notification system has already shown.
    //
    news: INewsConfig;
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
// On-disk contents of the `desktop` section.
//
export interface IYamlDesktopSection {
    // The folder the file dialog reopens at.
    last_folder?: string;

    // The folder the download dialog reopens at.
    last_download_folder?: string;

    // Recently executed searches, most recent first.
    recent_searches?: string[];

    // Whether the frames-per-second overlay is drawn.
    show_fps_indicator?: boolean;

    // Whether the native inspector should be reopened on startup.
    dev_tools_open?: boolean;
}

//
// On-disk contents of the `news` section.
//
export interface IYamlNewsSection {
    // Stable news item ids already shown on this install.
    shown_news_ids?: string[];

    // The release version that has already been announced to the user.
    last_shown_update_version?: string;
}

//
// The whole on-disk document (snake_case keys, sections nested by feature).
//
export interface IYamlConfigFile {
    // Which theme the interface uses.
    theme?: IConfigTheme;

    // Whether developer mode is on.
    developer_mode?: boolean;

    // Automatic photo import.
    auto_import?: IYamlAutoImportSection;

    // Automatic syncing.
    sync?: IYamlSyncSection;

    // Window-only preferences.
    desktop?: IYamlDesktopSection;

    // What the notification system has already shown.
    news?: IYamlNewsSection;
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
// Turns the `desktop` section into its in-memory form, dropping anything of the wrong type.
//
function yamlToDesktopSection(section: IYamlDesktopSection | undefined): IDesktopSection {
    if (!isSection(section)) {
        return {};
    }

    const desktop: IDesktopSection = {};
    if (typeof section!.last_folder === "string") {
        desktop.lastFolder = section!.last_folder;
    }
    if (typeof section!.last_download_folder === "string") {
        desktop.lastDownloadFolder = section!.last_download_folder;
    }
    if (Array.isArray(section!.recent_searches)) {
        desktop.recentSearches = section!.recent_searches.filter(search => typeof search === "string");
    }
    if (typeof section!.show_fps_indicator === "boolean") {
        desktop.showFpsIndicator = section!.show_fps_indicator;
    }
    if (typeof section!.dev_tools_open === "boolean") {
        desktop.devToolsOpen = section!.dev_tools_open;
    }
    return desktop;
}

//
// Turns the `news` section into its in-memory form.
//
// A malformed section comes back as an empty state rather than throwing, because the user must never
// be blocked from starting the app by what the notification system has recorded.
//
function yamlToNewsConfig(section: IYamlNewsSection | undefined): INewsConfig {
    if (!isSection(section)) {
        return { shownNewsIds: [] };
    }

    const news: INewsConfig = {
        shownNewsIds: Array.isArray(section!.shown_news_ids)
            ? section!.shown_news_ids.filter(newsId => typeof newsId === "string")
            : [],
    };
    if (typeof section!.last_shown_update_version === "string" && section!.last_shown_update_version.length > 0) {
        news.lastShownUpdateVersion = section!.last_shown_update_version;
    }
    return news;
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
        desktop: yamlToDesktopSection(parsed.desktop),
        news: yamlToNewsConfig(parsed.news),
    };

    if (typeof parsed.theme === "string" && ALLOWED_THEMES.includes(parsed.theme)) {
        config.theme = parsed.theme;
    }
    if (typeof parsed.developer_mode === "boolean") {
        config.developerMode = parsed.developer_mode;
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

    const desktop: IYamlDesktopSection = {};
    if (config.desktop.lastFolder !== undefined) {
        desktop.last_folder = config.desktop.lastFolder;
    }
    if (config.desktop.lastDownloadFolder !== undefined) {
        desktop.last_download_folder = config.desktop.lastDownloadFolder;
    }
    if (config.desktop.recentSearches !== undefined) {
        desktop.recent_searches = config.desktop.recentSearches;
    }
    if (config.desktop.showFpsIndicator !== undefined) {
        desktop.show_fps_indicator = config.desktop.showFpsIndicator;
    }
    if (config.desktop.devToolsOpen !== undefined) {
        desktop.dev_tools_open = config.desktop.devToolsOpen;
    }

    const news: IYamlNewsSection = {
        shown_news_ids: config.news.shownNewsIds,
    };
    if (config.news.lastShownUpdateVersion !== undefined) {
        news.last_shown_update_version = config.news.lastShownUpdateVersion;
    }

    const document: IYamlConfigFile = {};

    if (config.theme !== undefined) {
        document.theme = config.theme;
    }
    if (config.developerMode !== undefined) {
        document.developer_mode = config.developerMode;
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

    // These two go in only when they hold something. A phone never writes either, and an empty
    // section in its settings file is a line the reader has to work out means nothing.
    if (Object.keys(desktop).length > 0) {
        document.desktop = desktop;
    }
    if (news.shown_news_ids!.length > 0 || news.last_shown_update_version !== undefined) {
        document.news = news;
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
