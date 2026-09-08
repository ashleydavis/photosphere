//
// The on-disk contents of state.yaml and the conversions between it and the in-memory type.
//
// This is the sibling of config-format.ts, and the split between them is what each file is for.
// config.yaml holds what the user chose: the theme, what automatic import watches, whether syncing
// runs. state.yaml holds what the app remembers on its own so the interface comes back the way it was
// left: the folder a dialog last opened at, which sidebar sections are collapsed, how the gallery was
// sorted, which news has already been shown. Nobody edits state.yaml, and nothing in it is worth
// carrying to another machine, which is why it is not documented for users the way config.yaml is.
//
// It sits beside config.yaml, in ~/.config/photosphere on the CLI and the desktop app and at the root
// of the storage sandbox on a phone, and PHOTOSPHERE_CONFIG_DIR moves both together.
//
// Nothing here touches the filesystem, which is what lets it be bundled into the mobile worker, and
// it is the only definition of the file format, so the reader and the writer cannot drift apart.
//

import yaml from "js-yaml";

//
// A value the interface can keep under one of its own keys.
//
// The union is what the interface actually stores: a toggle, a remembered string, a count, or a list.
// It is narrow on purpose, because these values are written straight into the document under the key
// the interface chose, so anything that cannot be rendered as plain YAML would produce a file the next
// reader could not use.
//
export type IUiStateValue = boolean | number | string | string[];

//
// The interface's own keys, under the names the interface uses.
//
// Every other section of this file is named and typed here. This one is a map, because these keys
// cannot be declared in advance: a collapsible section builds its own key from its id, so a new one in
// a later release brings a new key with it. Before this section existed the desktop app accepted every
// one of these and then dropped it on the way to disk, so a collapsed sidebar never survived a restart.
//
export interface IUiSection {
    //
    // Each interface key and what was last stored under it.
    //
    [key: string]: IUiStateValue;
}

//
// One news item as the app has it in hand, which is the part of a published item a toast needs.
//
// Held here rather than reusing INewsItem from news-fetcher.ts because that module reads files and
// this one is bundled into the mobile worker, and because this is a cache of what was fetched rather
// than the published format itself.
//
export interface INewsFeedItem {
    // Stable id used to track whether the item has been shown.
    id: string;

    // The toast message.
    message: string;

    // Optional toast colour variant.
    color?: "primary" | "success" | "warning" | "danger" | "neutral";

    // Optional auto-dismiss duration in ms (0 or absent means no auto-dismiss).
    duration?: number;

    // Optional link shown in the toast.
    link?: string;
}

//
// What the notification system has already shown, so it does not show it twice, and the feed it has
// in hand to show from.
//
// Shared between the desktop app and the CLI on the same machine: an item announced by one is not
// announced again by the other.
//
export interface INewsState {
    //
    // Stable ids of news items already shown to the user, in the order they were first seen.
    //
    shownNewsIds: string[];

    //
    // The release version the user has already been told about. A newer release notifies again and
    // overwrites this.
    //
    lastShownUpdateVersion?: string;

    //
    // The feed the app last had in hand. The CLI and the desktop app fetch it each time and never
    // keep it, so this is only ever written on a phone, where there is nothing else to hold it.
    //
    feed: INewsFeedItem[];
}

//
// What the file dialogs and the developer tools remember. Only meaningful where there is a window.
//
export interface IStateDesktopSection {
    //
    // The folder the file dialog reopens at.
    //
    lastFolder?: string;

    //
    // The folder the download dialog reopens at.
    //
    lastDownloadFolder?: string;

    //
    // Whether the native inspector was open when the app closed, so it can be reopened on startup.
    //
    devToolsOpen?: boolean;
}

//
// What the search sidebar remembers. The searches the user deliberately SAVED are a setting and live
// in config.yaml; these are the ones they merely ran.
//
export interface ISearchesState {
    //
    // Recently executed searches, most recent first, capped at MAX_RECENT_SEARCHES.
    //
    recentSearches?: string[];
}

//
// How the gallery was last being looked at.
//
export interface IGalleryState {
    //
    // The field the gallery was sorted by.
    //
    sort?: string;

    //
    // The height of a gallery row, in pixels, as the user last dragged it.
    //
    rowHeight?: number;
}

//
// Everything state.yaml holds, in memory, with camelCase fields.
//
export interface IStateFile {
    //
    // What the file dialogs and the developer tools remember.
    //
    desktop: IStateDesktopSection;

    //
    // What the search sidebar remembers.
    //
    searches: ISearchesState;

    //
    // How the gallery was last being looked at.
    //
    gallery: IGalleryState;

    //
    // What the notification system has already shown, and the feed it has in hand.
    //
    news: INewsState;

    //
    // The interface's own working state, under the keys the interface uses.
    //
    ui: IUiSection;
}

//
// On-disk contents of the `desktop` section (snake_case keys).
//
export interface IYamlStateDesktopSection {
    // The folder the file dialog reopens at.
    last_folder?: string;

    // The folder the download dialog reopens at.
    last_download_folder?: string;

    // Whether the native inspector should be reopened on startup.
    dev_tools_open?: boolean;
}

//
// On-disk contents of the `searches` section.
//
export interface IYamlSearchesSection {
    // Recently executed searches, most recent first.
    recent?: string[];
}

//
// On-disk contents of the `gallery` section.
//
export interface IYamlGallerySection {
    // The field the gallery was sorted by.
    sort?: string;

    // The height of a gallery row, in pixels.
    row_height?: number;
}

//
// On-disk contents of one cached news item.
//
export interface IYamlNewsFeedItem {
    // Stable id of the item.
    id?: string;

    // The toast message.
    message?: string;

    // The toast colour variant.
    color?: string;

    // Auto-dismiss duration in ms.
    duration?: number;

    // Link shown in the toast.
    link?: string;
}

//
// On-disk contents of the `news` section.
//
export interface IYamlNewsSection {
    // Stable news item ids already shown on this install.
    shown_news_ids?: string[];

    // The release version that has already been announced to the user.
    last_shown_update_version?: string;

    // The feed the app last had in hand.
    feed?: IYamlNewsFeedItem[];
}

//
// On-disk contents of the `ui` section.
//
// The keys here are the interface's own, so unlike every other section they are not snake_case and are
// not listed: they are whatever the interface asked to store.
//
export interface IYamlUiSection {
    // Each interface key and its stored value.
    [key: string]: IUiStateValue;
}

//
// The whole on-disk document (snake_case keys, sections nested by what remembers them).
//
export interface IYamlStateFile {
    // What the file dialogs and the developer tools remember.
    desktop?: IYamlStateDesktopSection;

    // What the search sidebar remembers.
    searches?: IYamlSearchesSection;

    // How the gallery was last being looked at.
    gallery?: IYamlGallerySection;

    // What the notification system has already shown, and the feed it has in hand.
    news?: IYamlNewsSection;

    // The interface's own working state.
    ui?: IYamlUiSection;
}

//
// The toast colours a cached news item is allowed to name. An item naming anything else loses its
// colour rather than passing it through, because the value reaches the interface and picking a style
// by a name nobody defined leaves a toast with no styling at all.
//
export const ALLOWED_NEWS_COLORS: string[] = ["primary", "success", "warning", "danger", "neutral"];

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
// True when the value is one an interface key is allowed to hold.
//
export function isUiStateValue(value: any): value is IUiStateValue {
    if (typeof value === "boolean" || typeof value === "number" || typeof value === "string") {
        return true;
    }
    return Array.isArray(value) && value.every(entry => typeof entry === "string");
}

//
// Turns the `desktop` section into its in-memory form, dropping anything of the wrong type.
//
function yamlToStateDesktopSection(section: IYamlStateDesktopSection | undefined): IStateDesktopSection {
    if (!isSection(section)) {
        return {};
    }

    const desktop: IStateDesktopSection = {};
    if (typeof section!.last_folder === "string") {
        desktop.lastFolder = section!.last_folder;
    }
    if (typeof section!.last_download_folder === "string") {
        desktop.lastDownloadFolder = section!.last_download_folder;
    }
    if (typeof section!.dev_tools_open === "boolean") {
        desktop.devToolsOpen = section!.dev_tools_open;
    }
    return desktop;
}

//
// Turns the `searches` section into its in-memory form.
//
function yamlToSearchesState(section: IYamlSearchesSection | undefined): ISearchesState {
    if (!isSection(section)) {
        return {};
    }

    const searches: ISearchesState = {};
    if (Array.isArray(section!.recent)) {
        searches.recentSearches = section!.recent.filter(search => typeof search === "string");
    }
    return searches;
}

//
// Turns the `gallery` section into its in-memory form.
//
function yamlToGalleryState(section: IYamlGallerySection | undefined): IGalleryState {
    if (!isSection(section)) {
        return {};
    }

    const gallery: IGalleryState = {};
    if (typeof section!.sort === "string") {
        gallery.sort = section!.sort;
    }
    if (typeof section!.row_height === "number" && Number.isFinite(section!.row_height)) {
        gallery.rowHeight = section!.row_height;
    }
    return gallery;
}

//
// Turns one cached news item into its in-memory form, or undefined when it has nothing to show.
//
// An item with no id or no message is dropped: the id is how the app knows whether it has been shown,
// and the message is the whole toast, so an item missing either would either be announced forever or
// announced as an empty box.
//
function yamlToNewsFeedItem(item: IYamlNewsFeedItem): INewsFeedItem | undefined {
    if (!isSection(item) || typeof item.id !== "string" || typeof item.message !== "string") {
        return undefined;
    }

    const feedItem: INewsFeedItem = {
        id: item.id,
        message: item.message,
    };
    if (typeof item.color === "string" && ALLOWED_NEWS_COLORS.includes(item.color)) {
        feedItem.color = item.color as INewsFeedItem["color"];
    }
    if (typeof item.duration === "number" && Number.isFinite(item.duration)) {
        feedItem.duration = item.duration;
    }
    if (typeof item.link === "string") {
        feedItem.link = item.link;
    }
    return feedItem;
}

//
// Turns the `news` section into its in-memory form.
//
// A malformed section comes back as an empty state rather than throwing, because the user must never
// be blocked from starting the app by what the notification system has recorded.
//
function yamlToNewsState(section: IYamlNewsSection | undefined): INewsState {
    if (!isSection(section)) {
        return {
            shownNewsIds: [],
            feed: [],
        };
    }

    const feed: INewsFeedItem[] = [];
    if (Array.isArray(section!.feed)) {
        for (const rawItem of section!.feed) {
            const item = yamlToNewsFeedItem(rawItem);
            if (item !== undefined) {
                feed.push(item);
            }
        }
    }

    const news: INewsState = {
        shownNewsIds: Array.isArray(section!.shown_news_ids)
            ? section!.shown_news_ids.filter(newsId => typeof newsId === "string")
            : [],
        feed,
    };
    if (typeof section!.last_shown_update_version === "string" && section!.last_shown_update_version.length > 0) {
        news.lastShownUpdateVersion = section!.last_shown_update_version;
    }
    return news;
}

//
// Turns the `ui` section into its in-memory form, dropping any key holding something it could not have
// been written with.
//
// A dropped key reads as never having been set, which the interface already handles: a collapsible
// section with no stored state opens at its default.
//
function yamlToUiSection(section: IYamlUiSection | undefined): IUiSection {
    if (!isSection(section)) {
        return {};
    }

    const ui: IUiSection = {};
    for (const key of Object.keys(section!)) {
        const value = section![key];
        if (isUiStateValue(value)) {
            ui[key] = value;
        }
    }
    return ui;
}

//
// Turns the parsed document into the state the app works with.
//
// A section that is malformed falls back to that section's own defaults without discarding the
// sections that did parse, and a key nothing recognises is ignored rather than rejected.
//
export function yamlToStateFile(document: IYamlStateFile | undefined): IStateFile {
    const parsed: IYamlStateFile = isSection(document) ? document! : {};

    return {
        desktop: yamlToStateDesktopSection(parsed.desktop),
        searches: yamlToSearchesState(parsed.searches),
        gallery: yamlToGalleryState(parsed.gallery),
        news: yamlToNewsState(parsed.news),
        ui: yamlToUiSection(parsed.ui),
    };
}

//
// Converts one cached news item to its on-disk contents, writing only the fields it has.
//
function newsFeedItemToYaml(item: INewsFeedItem): IYamlNewsFeedItem {
    const yamlItem: IYamlNewsFeedItem = {
        id: item.id,
        message: item.message,
    };
    if (item.color !== undefined) {
        yamlItem.color = item.color;
    }
    if (item.duration !== undefined) {
        yamlItem.duration = item.duration;
    }
    if (item.link !== undefined) {
        yamlItem.link = item.link;
    }
    return yamlItem;
}

//
// Writes a section into the document, or leaves the document without it when it holds nothing, so a
// file never carries an empty section the next reader has to work out means nothing.
//
function writeSection(document: Record<string, any>, name: string, section: Record<string, any>): void {
    if (Object.keys(section).length > 0) {
        document[name] = section;
        return;
    }
    delete document[name];
}

//
// Turns the state into the document written to disk.
//
// An absent optional field stays absent rather than being written as null, so a file the app wrote
// holds only what it actually remembers.
//
export function stateFileToYaml(state: IStateFile): IYamlStateFile {
    const document: IYamlStateFile = {};

    const desktop: IYamlStateDesktopSection = {};
    if (state.desktop.lastFolder !== undefined) {
        desktop.last_folder = state.desktop.lastFolder;
    }
    if (state.desktop.lastDownloadFolder !== undefined) {
        desktop.last_download_folder = state.desktop.lastDownloadFolder;
    }
    if (state.desktop.devToolsOpen !== undefined) {
        desktop.dev_tools_open = state.desktop.devToolsOpen;
    }
    writeSection(document, "desktop", desktop);

    const searches: IYamlSearchesSection = {};
    if (state.searches.recentSearches !== undefined) {
        searches.recent = state.searches.recentSearches;
    }
    writeSection(document, "searches", searches);

    const gallery: IYamlGallerySection = {};
    if (state.gallery.sort !== undefined) {
        gallery.sort = state.gallery.sort;
    }
    if (state.gallery.rowHeight !== undefined) {
        gallery.row_height = state.gallery.rowHeight;
    }
    writeSection(document, "gallery", gallery);

    const news: IYamlNewsSection = {};
    if (state.news.shownNewsIds.length > 0) {
        news.shown_news_ids = state.news.shownNewsIds;
    }
    if (state.news.lastShownUpdateVersion !== undefined) {
        news.last_shown_update_version = state.news.lastShownUpdateVersion;
    }
    if (state.news.feed.length > 0) {
        news.feed = state.news.feed.map(newsFeedItemToYaml);
    }
    writeSection(document, "news", news);

    writeSection(document, "ui", { ...state.ui });

    return document;
}

//
// The state a reader falls back to when there is no file, used wherever a caller needs the defaults
// without having a document to convert.
//
export function defaultStateFile(): IStateFile {
    return yamlToStateFile(undefined);
}

//
// The result of parsing a state file: the state, and whether the text was readable at all.
//
export interface IParsedStateFile {
    //
    // The state. The defaults when the text could not be parsed.
    //
    state: IStateFile;

    //
    // True when the text is not valid YAML, so `state` is the defaults rather than anything the file
    // asked for. The caller reports it, so a file that has stopped working is not silent.
    //
    malformed: boolean;

    //
    // What the YAML parser said, when it refused the text. Absent otherwise.
    //
    parseError?: string;

    //
    // The document as it was parsed. Undefined for an empty file and for text that would not parse.
    //
    document?: IYamlStateFile;
}

//
// Parses the text of a state file, reporting whether it was readable.
//
// Text that will not parse comes back as the defaults rather than throwing, for the same reason an
// absent file does: nothing in here is worth refusing to start over. Losing it costs the user a
// collapsed sidebar and a remembered folder, and the app writes a fresh one as soon as anything is
// touched.
//
export function parseStateYamlChecked(text: string): IParsedStateFile {
    let document: IYamlStateFile | null | undefined;
    try {
        document = yaml.load(text) as IYamlStateFile | null | undefined;
    }
    catch (error) {
        return {
            state: defaultStateFile(),
            malformed: true,
            parseError: `${error}`,
        };
    }

    const parsed = document === null ? undefined : document;
    return {
        state: yamlToStateFile(parsed),
        malformed: false,
        document: isSection(parsed) ? parsed : undefined,
    };
}

//
// Renders the state as the text of a state file.
//
export function buildStateYaml(state: IStateFile): string {
    return yaml.dump(stateFileToYaml(state));
}
