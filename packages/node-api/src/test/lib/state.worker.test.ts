import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import yaml from "js-yaml";
import {
    readStateFromStorage,
    readStateHandler,
    writeStateHandler,
} from "../../lib/state.worker";

//
// Tests for the mobile state.yaml handlers.
//
// These run against the real filesystem rather than a mock, for the same reason the config.yaml tests
// do: the point of the handlers is the bytes they put on disk. What matters is that a file written by
// one is read by the others, not which functions were called.
//
// The handlers reach storage through FileStorage, which resolves relative paths against the process
// working directory on a host and against the app's sandbox root on a device, so the tests run from a
// temporary directory standing in for that sandbox.
//

//
// The task context the handlers take. They ignore it, so an empty object suffices.
//
const context: any = {};

//
// The path the tests read and write, relative to the temporary sandbox below.
//
const STATE_PATH = "state.yaml";

//
// A temporary working directory standing in for the app's storage sandbox, and the directory the
// test switches back to afterwards.
//
let tempDir: string;
let previousCwd: string;

beforeEach(async () => {
    previousCwd = process.cwd();
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-state-"));
    process.chdir(tempDir);
});

afterEach(async () => {
    process.chdir(previousCwd);
    await fs.rm(tempDir, { recursive: true, force: true });
});

//
// Writes the given text as the state file.
//
async function writeStateText(text: string): Promise<void> {
    await fs.writeFile(path.join(tempDir, STATE_PATH), text, "utf8");
}

//
// Reads the state file back as a parsed document.
//
async function readStateDocument(): Promise<any> {
    return yaml.load(await fs.readFile(path.join(tempDir, STATE_PATH), "utf8"));
}

describe("reading a sandbox with no state file", () => {

    test("yields nothing remembered rather than throwing", async () => {
        const result = await readStateHandler({ statePath: STATE_PATH }, context);

        expect(result.settings).toEqual({});
        expect(result.news.shownNewsIds).toEqual([]);
        expect(result.news.feed).toEqual([]);
        expect(result.news.lastShownUpdateVersion).toBeUndefined();
    });
});

describe("a corrupt state file", () => {

    test("reads as nothing remembered rather than throwing", async () => {
        // Nothing in this file is worth refusing to start over. Losing it costs a collapsed sidebar
        // and a remembered folder, and the app writes a fresh one as soon as anything is touched.
        await writeStateText("gallery:\n  sort: name\n   this: [is not yaml");

        const result = await readStateHandler({ statePath: STATE_PATH }, context);

        expect(result.settings).toEqual({});
    });
});

describe("the keys the interface names", () => {

    test("a key the format declares is written into its own section and read back by name", async () => {
        await writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "gallerySort", value: "name" }] }, context);

        expect((await readStateDocument()).gallery.sort).toBe("name");
        expect((await readStateHandler({ statePath: STATE_PATH }, context)).settings.gallerySort).toBe("name");
    });

    test("a key the format places in the desktop section goes there rather than to the top level", async () => {
        await writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "lastFolder", value: "/photos" }] }, context);

        const document = await readStateDocument();
        expect(document.desktop.last_folder).toBe("/photos");
        expect(document.last_folder).toBeUndefined();
        expect((await readStateHandler({ statePath: STATE_PATH }, context)).settings.lastFolder).toBe("/photos");
    });

    test("a key the format does not name is kept in the ui section rather than dropped", async () => {
        // The interface builds these keys from a component's id, so they cannot be declared in
        // advance. Before the ui section existed the desktop app accepted every one of them and then
        // dropped it on the way to disk, so a collapsed sidebar never survived a restart.
        await writeStateHandler({
            statePath: STATE_PATH,
            entries: [
                { key: "sidebar-collapsed-databases", value: true },
                { key: "right-sidebar-collapsed-selection", value: false },
            ],
        }, context);

        const document = await readStateDocument();
        expect(document.ui["sidebar-collapsed-databases"]).toBe(true);
        expect(document.ui["right-sidebar-collapsed-selection"]).toBe(false);

        const settings = (await readStateHandler({ statePath: STATE_PATH }, context)).settings;
        expect(settings["sidebar-collapsed-databases"]).toBe(true);
        expect(settings["right-sidebar-collapsed-selection"]).toBe(false);
    });

    test("an entry with no value clears the key rather than leaving it as it was", async () => {
        await writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "gallerySort", value: "name" }] }, context);
        await writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "gallerySort" }] }, context);

        expect((await readStateDocument()).gallery).toBeUndefined();
        expect((await readStateHandler({ statePath: STATE_PATH }, context)).settings.gallerySort).toBeUndefined();
    });

    test("clearing the last ui key takes the section with it", async () => {
        await writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "sidebar-collapsed-databases", value: true }] }, context);
        await writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "sidebar-collapsed-databases" }] }, context);

        expect((await readStateDocument()).ui).toBeUndefined();
    });

    test("writing one key leaves every other one as it was", async () => {
        await writeStateHandler({
            statePath: STATE_PATH,
            entries: [
                { key: "lastFolder", value: "/photos" },
                { key: "recentSearches", value: ["beach"] },
            ],
        }, context);

        await writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "gallerySort", value: "name" }] }, context);

        const settings = (await readStateHandler({ statePath: STATE_PATH }, context)).settings;
        expect(settings.lastFolder).toBe("/photos");
        expect(settings.recentSearches).toEqual(["beach"]);
        expect(settings.gallerySort).toBe("name");
    });
});

describe("the news state", () => {

    test("a written news state is read back", async () => {
        await writeStateHandler({
            statePath: STATE_PATH,
            news: {
                shownNewsIds: ["release-1", "survey-2"],
                lastShownUpdateVersion: "0.9.1",
                feed: [
                    {
                        id: "release-1",
                        message: "A new release",
                    },
                ],
            },
        }, context);

        const document = await readStateDocument();
        expect(document.news.shown_news_ids).toEqual(["release-1", "survey-2"]);
        expect(document.news.last_shown_update_version).toBe("0.9.1");
        expect(document.news.feed).toEqual([{ id: "release-1", message: "A new release" }]);

        const result = await readStateHandler({ statePath: STATE_PATH }, context);
        expect(result.news.shownNewsIds).toEqual(["release-1", "survey-2"]);
        expect(result.news.lastShownUpdateVersion).toBe("0.9.1");
        expect(result.news.feed).toEqual([{ id: "release-1", message: "A new release" }]);
    });

    test("a feed item with no id or no message is dropped rather than announced", async () => {
        // The id is how the app knows whether it has been shown and the message is the whole toast, so
        // an item missing either would be announced forever or announced as an empty box.
        await writeStateText([
            "news:",
            "  feed:",
            "    - id: good",
            "      message: A real item",
            "    - id: no-message",
            "    - message: no id",
            "",
        ].join("\n"));

        const result = await readStateHandler({ statePath: STATE_PATH }, context);
        expect(result.news.feed).toEqual([{ id: "good", message: "A real item" }]);
    });

    test("a feed item naming a colour nobody defined loses the colour and keeps the item", async () => {
        await writeStateText([
            "news:",
            "  feed:",
            "    - id: good",
            "      message: A real item",
            "      color: neon",
            "",
        ].join("\n"));

        const result = await readStateHandler({ statePath: STATE_PATH }, context);
        expect(result.news.feed).toEqual([{ id: "good", message: "A real item" }]);
    });

    test("writing the news state leaves the interface's keys alone", async () => {
        await writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "gallerySort", value: "name" }] }, context);

        await writeStateHandler({ statePath: STATE_PATH, news: { shownNewsIds: ["release-1"], feed: [] } }, context);

        const result = await readStateHandler({ statePath: STATE_PATH }, context);
        expect(result.settings.gallerySort).toBe("name");
        expect(result.news.shownNewsIds).toEqual(["release-1"]);
    });

    test("writing a key leaves the news state alone", async () => {
        await writeStateHandler({ statePath: STATE_PATH, news: { shownNewsIds: ["release-1"], feed: [] } }, context);

        await writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "gallerySort", value: "name" }] }, context);

        const result = await readStateHandler({ statePath: STATE_PATH }, context);
        expect(result.news.shownNewsIds).toEqual(["release-1"]);
        expect(result.settings.gallerySort).toBe("name");
    });
});

describe("bad input to the handlers", () => {

    test("a read with no path fails rather than reading nothing quietly", async () => {
        await expect(readStateHandler({ statePath: "" }, context)).rejects.toThrow(/statePath is required/);
    });

    test("a write with no path fails rather than writing nowhere quietly", async () => {
        await expect(writeStateHandler({ statePath: "" }, context)).rejects.toThrow(/statePath is required/);
    });

    test("a write with nothing to write fails rather than doing nothing quietly", async () => {
        await expect(writeStateHandler({ statePath: STATE_PATH }, context)).rejects.toThrow(/nothing to write/);
    });

    test("a key with no name fails rather than being written under an empty name", async () => {
        await expect(writeStateHandler({ statePath: STATE_PATH, entries: [{ key: "", value: true }] }, context))
            .rejects.toThrow(/no key/);
    });
});

describe("the file on disk", () => {

    test("is readable by the plain reader, so a phone and a desktop agree on it", async () => {
        await writeStateHandler({
            statePath: STATE_PATH,
            entries: [{ key: "lastFolder", value: "/photos" }],
        }, context);

        const contents = await readStateFromStorage(STATE_PATH);
        expect(contents.state.desktop.lastFolder).toBe("/photos");
    });
});
