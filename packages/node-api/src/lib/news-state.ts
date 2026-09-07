import { log } from "utils";
import { loadConfigFile, updateConfigFile } from "./config-file";
import type { INewsConfig } from "./config-format";

//
// Per-install state for the notification system, held in the `news` section of config.yaml
// ($PHOTOSPHERE_CONFIG_DIR/config.yaml, defaulting to ~/.config/photosphere/config.yaml) and shared
// between the desktop app and the CLI on the same machine, so a news item or update version surfaced
// on one surface is suppressed on the other.
//
// This is state rather than a setting, and it sits in the config file anyway so that the config
// directory holds one settings file rather than two.
//
// Not to be confused with the news.yaml in the root of the Photosphere repository, which is the
// published feed fetched over the network and has nothing to do with this.
//
export interface INewsState {
    //
    // Stable ids of news items that have already been shown to the user.
    //
    shownNewsIds: string[];

    //
    // Latest update version (e.g. "1.2.3") that the user has already been
    // notified about. When the GitHub-reported latest version equals this
    // value, the update notification is suppressed; when it differs the user
    // sees the notification again and this field is overwritten.
    //
    lastShownUpdateVersion?: string;
}

//
// Loads the news state. Returns an empty state when the config file is missing, empty, or malformed.
// The user must never be blocked by news-state failures.
//
// A file that cannot be read is reported rather than swallowed: it means something else has written
// a broken config, and the notifications going quiet is the only symptom anyone would otherwise see.
//
export async function loadNewsState(): Promise<INewsState> {
    let news: INewsConfig;
    try {
        news = (await loadConfigFile()).news;
    }
    catch (error) {
        log.error(`The news state could not be read, carrying on with an empty one: ${error}`);
        return { shownNewsIds: [] };
    }

    const state: INewsState = {
        shownNewsIds: news.shownNewsIds.slice(),
    };
    if (news.lastShownUpdateVersion !== undefined) {
        state.lastShownUpdateVersion = news.lastShownUpdateVersion;
    }
    return state;
}

//
// Saves the news state into the `news` section of the config file, leaving every other section
// exactly as it is. It goes through updateConfigFile rather than a load-then-save so a setting changed
// between this read and this write is not discarded.
//
export async function saveNewsState(state: INewsState): Promise<void> {
    await updateConfigFile(config => {
        config.news = {
            shownNewsIds: state.shownNewsIds,
        };
        if (state.lastShownUpdateVersion !== undefined) {
            config.news.lastShownUpdateVersion = state.lastShownUpdateVersion;
        }
    });
}

//
// Returns the list of news item ids that have already been shown on this install.
//
export async function getShownNewsIds(): Promise<string[]> {
    const state = await loadNewsState();
    return state.shownNewsIds;
}

//
// Appends the given news item ids to the persisted set, deduping the union of
// existing + new ids while preserving the order in which ids were first seen.
//
export async function addShownNewsIds(ids: string[]): Promise<void> {
    if (ids.length === 0) {
        return;
    }

    await updateConfigFile(config => {
        const existing = config.news.shownNewsIds;
        const seen = new Set<string>(existing);
        const merged: string[] = existing.slice();
        for (const id of ids) {
            if (!seen.has(id)) {
                seen.add(id);
                merged.push(id);
            }
        }
        config.news.shownNewsIds = merged;
    });
}

//
// Returns the latest update version the user has already been notified about,
// or undefined when no update has been shown yet.
//
export async function getLastShownUpdateVersion(): Promise<string | undefined> {
    const state = await loadNewsState();
    return state.lastShownUpdateVersion;
}

//
// Records the given update version as having been shown to the user. Subsequent
// checkForUpdates() calls that return the same version will suppress their
// notification; a newer GitHub release will re-trigger the notification and
// overwrite this field.
//
export async function setLastShownUpdateVersion(version: string): Promise<void> {
    await updateConfigFile(config => {
        config.news.lastShownUpdateVersion = version;
    });
}
