import { log } from "utils";
import { loadStateFile, updateStateFile } from "./state-file";
import type { INewsState } from "./state-format";

//
// Per-install state for the notification system, held in the `news` section of state.yaml
// ($PHOTOSPHERE_CONFIG_DIR/state.yaml, defaulting to ~/.config/photosphere/state.yaml) and shared
// between the desktop app and the CLI on the same machine, so a news item or update version surfaced
// on one surface is suppressed on the other.
//
// It is in the state file rather than the config file because nobody chose any of it: it is what the
// app has already told the user, recorded so it does not tell them twice.
//
// Not to be confused with the news.yaml in the root of the Photosphere repository, which is the
// published feed fetched over the network and has nothing to do with this.
//
export type { INewsState };

//
// Loads the news state. Returns an empty state when the state file is missing, empty, or malformed.
// The user must never be blocked by news-state failures.
//
// A file that cannot be read is reported rather than swallowed: it means something else has written a
// broken file, and the notifications going quiet is the only symptom anyone would otherwise see.
//
export async function loadNewsState(): Promise<INewsState> {
    try {
        const news = (await loadStateFile()).news;
        const state: INewsState = {
            shownNewsIds: news.shownNewsIds.slice(),
            feed: news.feed.slice(),
        };
        if (news.lastShownUpdateVersion !== undefined) {
            state.lastShownUpdateVersion = news.lastShownUpdateVersion;
        }
        return state;
    }
    catch (error) {
        log.error(`The news state could not be read, carrying on with an empty one: ${error}`);
        return {
            shownNewsIds: [],
            feed: [],
        };
    }
}

//
// Saves the news state into the `news` section of the state file, leaving every other section exactly
// as it is. It goes through updateStateFile rather than a load-then-save so anything changed between
// this read and this write is not discarded.
//
export async function saveNewsState(state: INewsState): Promise<void> {
    await updateStateFile(stateFile => {
        stateFile.news = {
            shownNewsIds: state.shownNewsIds,
            feed: state.feed,
        };
        if (state.lastShownUpdateVersion !== undefined) {
            stateFile.news.lastShownUpdateVersion = state.lastShownUpdateVersion;
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

    await updateStateFile(stateFile => {
        const existing = stateFile.news.shownNewsIds;
        const seen = new Set<string>(existing);
        const merged: string[] = existing.slice();
        for (const id of ids) {
            if (!seen.has(id)) {
                seen.add(id);
                merged.push(id);
            }
        }
        stateFile.news.shownNewsIds = merged;
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
    await updateStateFile(stateFile => {
        stateFile.news.lastShownUpdateVersion = version;
    });
}
