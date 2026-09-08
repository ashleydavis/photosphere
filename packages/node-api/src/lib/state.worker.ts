//
// Reads and writes state.yaml as a background task.
//
// The sibling of config.worker.ts and the same arrangement, for the same reason: the mobile WebView
// holds this state but cannot open a file, so its reads and writes run in the embedded worker over
// the storage layer.
//
// A write merges rather than replaces: it reads what is on disk, changes only what the caller sent,
// and writes the whole document back, so a sidebar collapsing does not take the news state with it.
//
// The file contents come from state-format.ts, the same module every reader converts through, so a
// file written here is readable by anything else that opens it by construction.
//

import yaml from "js-yaml";
import type { ITaskContext } from "task-queue";
import { log } from "utils";
import { FileStorage } from "storage";
import {
    defaultStateFile,
    parseStateYamlChecked,
    stateFileToYaml,
    type INewsFeedItem,
    type INewsState,
    type IStateFile,
    type IYamlStateFile,
} from "./state-format";
import {
    appStateSettings,
    appStateToYaml,
    setAppStateValue,
    yamlToAppState,
    type IAppStateValue,
} from "./app-state-format";

//
// Input for the read-state task.
//
export interface IReadStateData {
    // Sandbox-relative path of state.yaml.
    statePath: string;
}

//
// One state key the caller is changing.
//
// A missing `value` clears the key, which is what IConfig.clear means, and is not the same as the
// entry not being sent at all. The two have to be told apart because the entry crosses the bridge to
// the phone as JSON, where an undefined property simply disappears: a caller that meant "clear this"
// would arrive looking like a caller that meant nothing, so the key would be left as it was.
//
export interface IWriteStateEntry {
    // The flat key the interface uses.
    key: string;

    // What to store under it. Absent clears the key.
    value?: IAppStateValue;
}

//
// The news part of a write, sent only when the caller is changing it.
//
export interface IWriteStateNews {
    // Ids of news items already shown, in the order they were first seen.
    shownNewsIds: string[];

    // The release already announced to the user, or undefined when none has been.
    lastShownUpdateVersion?: string;

    // The feed the app has in hand.
    feed: INewsFeedItem[];
}

//
// Input for the write-state task.
//
// Every part is optional, and a part that is absent is left as it is on disk.
//
export interface IWriteStateData {
    // Sandbox-relative path of state.yaml.
    statePath: string;

    // The state keys being changed, each written where this file keeps it.
    entries?: IWriteStateEntry[];

    // The news state, when that is what is being changed.
    news?: IWriteStateNews;
}

//
// Result of the read-state task.
//
export interface IReadStateResult {
    // Every state key that has a value, under the flat name the interface uses for it. Flat rather
    // than the sectioned document so the phone's WebView can answer a get by indexing it.
    settings: Record<string, IAppStateValue>;

    // What the notification system has already shown, and the feed it has in hand.
    news: INewsState;
}

//
// What reading the file gives back: the state, and the document it came from.
//
export interface IStateRead {
    // The state, filled from the defaults for anything the file did not say.
    state: IStateFile;

    // The document as it was on disk, which is what the flat key/value view is built from. Undefined
    // when there is no file, or when it would not parse.
    document?: IYamlStateFile;
}

//
// Reads the state file through storage, which is how it is reached on a device.
//
// A file that is not there, and one that will not parse, both come back as the defaults rather than
// throwing. Nothing in here is worth refusing to start over: losing it costs a collapsed sidebar and a
// remembered folder. The parse failure is logged so it is not silent.
//
export async function readStateFromStorage(statePath: string): Promise<IStateRead> {
    const storage = new FileStorage("fs:");
    const absent: IStateRead = {
        state: defaultStateFile(),
    };

    if (!await storage.fileExists(statePath)) {
        return absent;
    }

    const contents = await storage.read(statePath);
    if (!contents) {
        return absent;
    }

    const parsed = parseStateYamlChecked(contents.toString("utf8"));
    if (parsed.malformed) {
        log.error(`The state at "${statePath}" could not be parsed, using the defaults: ${parsed.parseError}`);
    }
    return {
        state: parsed.state,
        document: parsed.document,
    };
}

//
// Handler for the read-state task.
//
export async function readStateHandler(data: IReadStateData, _context: ITaskContext): Promise<IReadStateResult> {
    if (!data.statePath) {
        throw new Error("statePath is required");
    }

    const contents = await readStateFromStorage(data.statePath);

    return {
        settings: appStateSettings(yamlToAppState(contents.document)),
        news: contents.state.news,
    };
}

//
// Handler for the write-state task.
//
// A read-modify-write: it reads what is on disk, replaces only what the caller sent, and writes the
// whole document back. Reading first is what keeps everything nobody touched.
//
export async function writeStateHandler(data: IWriteStateData, _context: ITaskContext): Promise<void> {
    if (!data.statePath) {
        throw new Error("statePath is required");
    }
    if (!data.entries && !data.news) {
        throw new Error("write-state was given no settings and no news section, so there is nothing to write.");
    }

    const storage = new FileStorage("fs:");
    const contents = await readStateFromStorage(data.statePath);
    const current = contents.state;

    if (data.news) {
        current.news = {
            shownNewsIds: data.news.shownNewsIds,
            feed: data.news.feed,
        };
        if (data.news.lastShownUpdateVersion !== undefined) {
            current.news.lastShownUpdateVersion = data.news.lastShownUpdateVersion;
        }
    }

    let document = stateFileToYaml(current);

    // The keys the interface names go on last, through the flat view, which is the only thing that
    // knows which section each of them belongs in. It merges into the document rather than rebuilding
    // it, so it changes the keys it was given and leaves the rest of the file alone.
    if (data.entries) {
        const appState = yamlToAppState(document);
        for (const entry of data.entries) {
            if (!entry.key) {
                throw new Error("write-state was given a setting with no key.");
            }
            setAppStateValue(appState, entry.key, entry.value);
        }
        document = appStateToYaml(appState, document);
    }

    const text = yaml.dump(document);
    await storage.write(data.statePath, "application/yaml", Buffer.from(text, "utf8"));
}
