import * as os from "os";
import * as path from "path";
import { readFile, writeFile, mkdir } from "fs/promises";
import yaml from "js-yaml";

//
// Per-install state for the notification system. Stored as YAML at
// $PHOTOSPHERE_CONFIG_DIR/news.yaml (defaults to ~/.config/photosphere/news.yaml)
// and shared between the desktop app and the CLI on the same machine, so a news
// item or update version surfaced on one surface is suppressed on the other.
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
// On-disk YAML shape (snake_case keys, plain primitives only).
//
interface IYamlNewsState {
    // Stable news item ids already shown on this install.
    shown_news_ids?: string[];

    // Latest update version that has already been announced to the user.
    last_shown_update_version?: string;
}

const CONFIG_DIR = process.env.PHOTOSPHERE_CONFIG_DIR || path.join(os.homedir(), ".config", "photosphere");
const STATE_FILE = path.join(CONFIG_DIR, "news.yaml");

//
// Returns the absolute path of the news state file. Useful for tests and demo scripts.
//
export function getNewsStatePath(): string {
    return STATE_FILE;
}

//
// Loads the news state from disk. Returns an empty state when the file is missing,
// empty, or malformed. The user must never be blocked by news-state failures.
//
export async function loadNewsState(): Promise<INewsState> {
    let raw: string;
    try {
        raw = await readFile(STATE_FILE, "utf-8");
    }
    catch (error) {
        return { shownNewsIds: [] };
    }

    let parsed: IYamlNewsState | null | undefined;
    try {
        parsed = yaml.load(raw) as IYamlNewsState | null | undefined;
    }
    catch (error) {
        return { shownNewsIds: [] };
    }

    if (!parsed || typeof parsed !== "object") {
        return { shownNewsIds: [] };
    }

    const state: INewsState = {
        shownNewsIds: Array.isArray(parsed.shown_news_ids) ? parsed.shown_news_ids.slice() : [],
    };
    if (typeof parsed.last_shown_update_version === "string" && parsed.last_shown_update_version.length > 0) {
        state.lastShownUpdateVersion = parsed.last_shown_update_version;
    }
    return state;
}

//
// Saves the news state to disk, creating the config directory if needed.
//
export async function saveNewsState(state: INewsState): Promise<void> {
    const yamlShape: IYamlNewsState = {
        shown_news_ids: state.shownNewsIds,
    };
    if (state.lastShownUpdateVersion !== undefined) {
        yamlShape.last_shown_update_version = state.lastShownUpdateVersion;
    }
    await mkdir(CONFIG_DIR, { recursive: true });
    await writeFile(STATE_FILE, yaml.dump(yamlShape), "utf-8");
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
    const state = await loadNewsState();
    const existing = state.shownNewsIds;
    const seen = new Set<string>(existing);
    const merged: string[] = existing.slice();
    for (const id of ids) {
        if (!seen.has(id)) {
            seen.add(id);
            merged.push(id);
        }
    }
    state.shownNewsIds = merged;
    await saveNewsState(state);
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
    const state = await loadNewsState();
    state.lastShownUpdateVersion = version;
    await saveNewsState(state);
}
