//
// The state store the shared UI reads and writes through, backed by state.yaml.
//
// The sibling of app-config.ts. That one holds what the user chose; this one holds what the app
// remembered so the interface comes back the way it was left: the folder a dialog last opened at, the
// searches that were merely run, how the gallery was sorted, which sidebar sections are collapsed.
//
// What the state keys mean is not decided here. app-state-format.ts owns that, and is where the flat
// view and its conversions live, so the phone's worker can be handed the same definition without
// dragging the filesystem in with it. This module is the file half: loading it, and changing it.
//

import { readYaml, updateYaml } from "node-utils";
import { getStatePath } from "./state-file";
import { yamlToAppState, appStateToYaml, MAX_RECENT_SEARCHES, type IAppState } from "./app-state-format";
import type { IYamlStateFile } from "./state-format";

export * from "./app-state-format";

//
// Loads the whole state from disk.
// Returns an empty state when the file does not exist, so every key falls to its own default.
//
export async function loadAppState(): Promise<IAppState> {
    const document = await readYaml<IYamlStateFile>(getStatePath());
    return yamlToAppState(document);
}

//
// Changes the state on disk. Every edit goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place, under the update lock
// beside the file, so two edits arriving together both survive rather than the second discarding the
// first.
//
export async function updateAppState(mutator: (state: IAppState) => void): Promise<void> {
    await updateYaml<IYamlStateFile>(getStatePath(), {}, (document) => {
        const state = yamlToAppState(document);
        mutator(state);
        return appStateToYaml(state, document);
    });
}

//
// The state keys that remember a folder chosen in a folder picker.
//
export type FolderStateKey = 'lastFolder' | 'lastDownloadFolder';

//
// Every state key a folder picker is allowed to read from and write back to.
//
export const FOLDER_STATE_KEYS: FolderStateKey[] = ['lastFolder', 'lastDownloadFolder'];

//
// Narrows a folder key to one the state actually holds, throwing when it is not one of them.
//
// The key arrives from the renderer as a plain string, so without this an unrecognised key would be
// written under a name nothing ever reads, and the picker would silently forget the folder every time.
//
export function asFolderStateKey(folderKey: string): FolderStateKey {
    const found = FOLDER_STATE_KEYS.find(candidate => candidate === folderKey);
    if (found === undefined) {
        throw new Error(`Unknown folder state key "${folderKey}". Expected one of: ${FOLDER_STATE_KEYS.join(', ')}.`);
    }
    return found;
}

//
// Gets the folder remembered under a folder picker's key, used as the dialog's starting directory.
// Returns undefined when no folder has been remembered under that key yet.
//
export async function getFolderPath(folderKey: string): Promise<string | undefined> {
    // Checked before the file is opened, so an unrecognised key is refused without a read.
    const key = asFolderStateKey(folderKey);
    const state = await loadAppState();
    return state[key];
}

//
// Remembers the folder a user chose under a folder picker's key.
//
// Only that one key is written, and it is written against the file's CURRENT contents. A folder
// picker stays open for as long as the user takes to choose, so a state read before the dialog opened
// is stale by the time it closes, and writing that whole state back would undo anything changed in
// the meantime.
//
export async function updateFolderPath(folderKey: string, folderPath: string): Promise<void> {
    const key = asFolderStateKey(folderKey);
    await updateAppState(state => {
        state[key] = folderPath;
    });
}

//
// Updates the last folder that was opened in the file dialog.
//
export async function updateLastFolder(folderPath: string): Promise<void> {
    await updateAppState(state => {
        state.lastFolder = folderPath;
    });
}

//
// Updates the last folder used when downloading assets.
//
export async function updateLastDownloadFolder(folderPath: string): Promise<void> {
    await updateAppState(state => {
        state.lastDownloadFolder = folderPath;
    });
}

//
// Gets the recent searches list.
//
export async function getRecentSearches(): Promise<string[]> {
    const state = await loadAppState();
    return state.recentSearches || [];
}

//
// Adds a search to the recent searches list, deduplicating and capping at MAX_RECENT_SEARCHES.
//
export async function addRecentSearch(searchText: string): Promise<void> {
    await updateAppState(state => {
        const filtered = (state.recentSearches || []).filter(item => item !== searchText);
        state.recentSearches = [searchText, ...filtered].slice(0, MAX_RECENT_SEARCHES);
    });
}

//
// Removes a search from the recent searches list.
//
export async function removeRecentSearch(searchText: string): Promise<void> {
    await updateAppState(state => {
        state.recentSearches = (state.recentSearches || []).filter(item => item !== searchText);
    });
}
