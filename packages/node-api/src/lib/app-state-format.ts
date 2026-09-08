//
// The flat key/value view of state.yaml that the interface works in.
//
// The sibling of app-config-format.ts, and the same idea: `IConfig` in user-interface offers get and
// set over a plain string key, and the interface knows nothing about where any of them are kept. This
// module is the one definition of what the state keys mean, which section of state.yaml each one sits
// in, and what it is called on disk.
//
// Nothing decides which of the two files a key belongs to, because nothing has to: the interface has
// a context per store and the caller asks the one it means.
//
// It touches no filesystem, which is what lets it be bundled into the mobile worker. The functions
// that open the file are in state-file.ts.
//
// Like the config view it maps the raw document rather than filled-in defaults, so absent means
// absent and the interface can apply its own default to a key nobody has touched.
//

import { isUiStateValue, type IUiSection, type IUiStateValue, type IYamlGallerySection, type IYamlSearchesSection, type IYamlStateDesktopSection, type IYamlStateFile, type IYamlUiSection } from "./state-format";

//
// Every state key the interface can reach by name, flattened into one namespace.
//
export interface IAppState {
    //
    // The last folder that was opened in the file dialog.
    //
    lastFolder?: string;

    //
    // The last folder used when downloading assets.
    //
    lastDownloadFolder?: string;

    //
    // Whether the developer tools were open when the app closed, so they can be reopened on startup.
    //
    devToolsOpen?: boolean;

    //
    // Searches recently executed, most recent first.
    //
    recentSearches?: string[];

    //
    // The field the gallery was last sorted by.
    //
    gallerySort?: string;

    //
    // The height of a gallery row, in pixels, as the user last dragged it.
    //
    galleryRowHeight?: number;

    //
    // Every key above is one this module places in a section of its own. This holds the rest: the
    // interface's own working state, under whatever key the interface chose for it.
    //
    ui?: IUiSection;
}

//
// A value one of the flat state keys can hold.
//
export type IAppStateValue = IUiStateValue;

//
// How many searches the recent list keeps.
//
export const MAX_RECENT_SEARCHES = 10;

//
// The flat keys this module places in a section of the document.
//
// Everything else the interface asks for goes to the `ui` section under its own name, which is what
// lets a collapsible section store its state under a key built from its id. This list is the only
// thing that decides which of the two a key gets, so a key cannot be read from one place and written
// to another.
//
export const DECLARED_APP_STATE_KEYS: string[] = [
    "lastFolder",
    "lastDownloadFolder",
    "devToolsOpen",
    "recentSearches",
    "gallerySort",
    "galleryRowHeight",
];

//
// Reads one flat state key, wherever this module keeps it. undefined when nothing is stored under it.
//
export function getAppStateValue(state: IAppState, key: string): IAppStateValue | undefined {
    if (DECLARED_APP_STATE_KEYS.includes(key)) {
        return (state as Record<string, IAppStateValue | undefined>)[key];
    }
    return state.ui ? state.ui[key] : undefined;
}

//
// Writes one flat state key, wherever this module keeps it. undefined removes it, which is what
// IConfig.clear means.
//
export function setAppStateValue(state: IAppState, key: string, value: IAppStateValue | undefined): void {
    if (DECLARED_APP_STATE_KEYS.includes(key)) {
        const fields = state as Record<string, IAppStateValue | undefined>;
        if (value === undefined) {
            delete fields[key];
        }
        else {
            fields[key] = value;
        }
        return;
    }

    if (value === undefined) {
        if (state.ui) {
            delete state.ui[key];
        }
        return;
    }

    if (!state.ui) {
        state.ui = {};
    }
    state.ui[key] = value;
}

//
// Every state key that has a value, under the name the interface uses for it.
//
// The whole store in one object, for a caller that wants to read by name without knowing which
// section each key sits in. A key kept in the `ui` section appears here beside the declared ones, and
// the two can never collide because setAppStateValue sends a declared key to its own field and
// everything else to `ui`.
//
export function appStateSettings(state: IAppState): Record<string, IAppStateValue> {
    const settings: Record<string, IAppStateValue> = {};

    for (const key of DECLARED_APP_STATE_KEYS) {
        const value = (state as Record<string, IAppStateValue | undefined>)[key];
        if (value !== undefined) {
            settings[key] = value;
        }
    }

    if (state.ui) {
        for (const key of Object.keys(state.ui)) {
            settings[key] = state.ui[key];
        }
    }

    return settings;
}

//
// True when the value is an object we can read keys off, and not an array or null.
//
function isSection(value: any): boolean {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

//
// Flattens the on-disk document into the key/value view the interface works in.
//
export function yamlToAppState(document: IYamlStateFile | undefined): IAppState {
    const state: IAppState = {};
    if (!isSection(document)) {
        return state;
    }

    if (isSection(document!.desktop)) {
        const desktop = document!.desktop!;
        if (typeof desktop.last_folder === "string") {
            state.lastFolder = desktop.last_folder;
        }
        if (typeof desktop.last_download_folder === "string") {
            state.lastDownloadFolder = desktop.last_download_folder;
        }
        if (typeof desktop.dev_tools_open === "boolean") {
            state.devToolsOpen = desktop.dev_tools_open;
        }
    }

    if (isSection(document!.searches)) {
        const searches = document!.searches!;
        if (Array.isArray(searches.recent)) {
            state.recentSearches = searches.recent.filter(search => typeof search === "string");
        }
    }

    if (isSection(document!.gallery)) {
        const gallery = document!.gallery!;
        if (typeof gallery.sort === "string") {
            state.gallerySort = gallery.sort;
        }
        if (typeof gallery.row_height === "number" && Number.isFinite(gallery.row_height)) {
            state.galleryRowHeight = gallery.row_height;
        }
    }

    if (isSection(document!.ui)) {
        const ui: IUiSection = {};
        for (const key of Object.keys(document!.ui!)) {
            const value = document!.ui![key];
            if (isUiStateValue(value)) {
                ui[key] = value;
            }
        }
        state.ui = ui;
    }

    return state;
}

//
// Writes one field into a section, or removes it from the section when it has been cleared.
//
// Removing matters because this view is built from the document: a field that is absent here was
// absent there, so writing "nothing" back has to mean the key goes, or IConfig.clear would report
// success and change nothing on disk.
//
function writeField(section: Record<string, any>, key: string, value: any): void {
    if (value === undefined) {
        delete section[key];
        return;
    }
    section[key] = value;
}

//
// Writes a section into the document, or leaves the document without it when it holds nothing.
//
function writeSection(document: Record<string, any>, name: string, section: Record<string, any>): void {
    if (Object.keys(section).length > 0) {
        document[name] = section;
        return;
    }
    delete document[name];
}

//
// Writes the flat view back into the document, leaving everything this view does not own where it is.
//
// The merge matters: the document also carries the news state, which does not appear in the flat view.
// Rebuilding the document from the flat view alone would drop it every time a sidebar section was
// collapsed.
//
export function appStateToYaml(state: IAppState, document: IYamlStateFile): IYamlStateFile {
    const merged: IYamlStateFile = isSection(document) ? { ...document } : {};

    const desktop: IYamlStateDesktopSection = isSection(merged.desktop) ? { ...merged.desktop } : {};
    writeField(desktop, "last_folder", state.lastFolder);
    writeField(desktop, "last_download_folder", state.lastDownloadFolder);
    writeField(desktop, "dev_tools_open", state.devToolsOpen);
    writeSection(merged, "desktop", desktop);

    const searches: IYamlSearchesSection = isSection(merged.searches) ? { ...merged.searches } : {};
    writeField(searches, "recent", state.recentSearches);
    writeSection(merged, "searches", searches);

    const gallery: IYamlGallerySection = isSection(merged.gallery) ? { ...merged.gallery } : {};
    writeField(gallery, "sort", state.gallerySort);
    writeField(gallery, "row_height", state.galleryRowHeight);
    writeSection(merged, "gallery", gallery);

    const ui: IYamlUiSection = state.ui ? { ...state.ui } : {};
    writeSection(merged, "ui", ui);

    return merged;
}
