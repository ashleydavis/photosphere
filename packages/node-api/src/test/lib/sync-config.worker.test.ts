import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import { parse as parseToml } from "smol-toml";
import { DEFAULT_SYNC_PAUSE_MS } from "api/src/lib/sync-settings";
import {
    buildSyncConfigToml,
    readSyncConfigFile,
    readSyncConfigHandler,
    writeSyncConfigHandler,
} from "../../lib/sync-config.worker";

//
// Tests for the mobile sync.toml handlers.
//
// These run against the real filesystem rather than a mock, for the same reason the auto-import.toml
// tests do: the point of the handlers is the bytes they put on disk. The settings are read by the
// app and by the background sync loop, so what matters is that a file written by one is read by the
// other, not which functions were called.
//
// The handlers reach storage through FileStorage, which resolves relative paths against the process
// working directory on a host and against the app's sandbox root on a device, so the tests run from
// a temporary directory standing in for that sandbox.
//

//
// The task context the handlers take. They ignore it, so an empty object suffices.
//
const context: any = {};

//
// The path the tests read and write, relative to the temporary sandbox below.
//
const CONFIG_PATH = "sync.toml";

//
// A temporary working directory standing in for the app's storage sandbox, and the directory the
// test switches back to afterwards.
//
let tempDir: string;
let previousCwd: string;

beforeEach(async () => {
    previousCwd = process.cwd();
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-sync-config-"));
    process.chdir(tempDir);
});

afterEach(async () => {
    process.chdir(previousCwd);
    await fs.rm(tempDir, { recursive: true, force: true });
});

describe("mobile sync.toml", () => {

    test("reading a file that does not exist yields syncing switched off", async () => {
        // The safe answer, and the whole reason the defaults are what they are: a background loop
        // that cannot read its settings must not start pushing photos over a metered connection.
        const result = await readSyncConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.settings.enabled).toBe(false);
        expect(result.settings.onlyOnWifi).toBe(true);
        expect(result.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
    });

    test("reading a file that does not exist says so", async () => {
        // The interface needs to tell "nobody has written this yet" from "somebody switched syncing
        // off", because the first is a fresh install to seed and the second is a decision to leave
        // alone, and both read as switched off.
        const result = await readSyncConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.exists).toBe(false);
    });

    test("a file that will not parse reads as syncing switched off rather than throwing", async () => {
        // This file is written by the app and never shown to the user, so a copy that cannot be read
        // is a bug somewhere else. Throwing here would take the settings card that could fix it down
        // with it, and reading it as "sync over anything" would spend somebody's mobile data.
        await fs.writeFile(path.join(tempDir, CONFIG_PATH), "this is not = = toml [[[", "utf8");

        const result = await readSyncConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.settings.enabled).toBe(false);
        expect(result.settings.onlyOnWifi).toBe(true);
        expect(result.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
    });

    test("a file that is there says so, even when it says syncing is off", async () => {
        await writeSyncConfigHandler({
            configPath: CONFIG_PATH,
            settings: {
                enabled: false,
                onlyOnWifi: false,
            },
            pauseBetweenRunsMs: DEFAULT_SYNC_PAUSE_MS,
        }, context);

        const result = await readSyncConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.exists).toBe(true);
        expect(result.settings.enabled).toBe(false);
    });

    test("writing then reading round-trips both settings and the pacing", async () => {
        await writeSyncConfigHandler({
            configPath: CONFIG_PATH,
            settings: {
                enabled: true,
                onlyOnWifi: false,
            },
            pauseBetweenRunsMs: 60000,
        }, context);

        const result = await readSyncConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.settings.enabled).toBe(true);
        expect(result.settings.onlyOnWifi).toBe(false);
        expect(result.pauseBetweenRunsMs).toBe(60000);
    });

    test("the file is TOML with snake_case keys", async () => {
        // Asserted on the file itself, because anything else that opens it (a smoke test seeding
        // settings from outside the app, a person looking at what their phone is doing) reads these
        // names rather than the TypeScript ones.
        await writeSyncConfigHandler({
            configPath: CONFIG_PATH,
            settings: {
                enabled: true,
                onlyOnWifi: true,
            },
            pauseBetweenRunsMs: 300000,
        }, context);

        const toml: any = parseToml(await fs.readFile(path.join(tempDir, CONFIG_PATH), "utf8"));

        expect(toml.enabled).toBe(true);
        expect(toml.only_on_wifi).toBe(true);
        expect(toml.pause_between_runs_ms).toBe(300000);
    });

    test("a gap of zero or less falls back to the default rather than spinning", async () => {
        // A gap of zero is a loop that starts a fresh pass the instant the last one ended, which on a
        // phone is a flat battery. The value can only get here by hand, so it is corrected on the way
        // in and on the way out.
        await fs.writeFile(
            path.join(tempDir, CONFIG_PATH),
            "enabled = true\npause_between_runs_ms = 0\n",
            "utf8");

        const zeroGap = await readSyncConfigHandler({ configPath: CONFIG_PATH }, context);
        expect(zeroGap.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);

        await fs.writeFile(
            path.join(tempDir, CONFIG_PATH),
            "enabled = true\npause_between_runs_ms = -1000\n",
            "utf8");

        const negativeGap = await readSyncConfigHandler({ configPath: CONFIG_PATH }, context);
        expect(negativeGap.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
    });

    test("a value that is not a boolean is not taken as one", async () => {
        // A hand-edited file may hold anything. The string "false" is truthy, so coercing it would
        // switch syncing on for somebody who wrote the opposite.
        await fs.writeFile(
            path.join(tempDir, CONFIG_PATH),
            'enabled = "false"\nonly_on_wifi = "no"\n',
            "utf8");

        const result = await readSyncConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.settings.enabled).toBe(false);
        expect(result.settings.onlyOnWifi).toBe(true);
    });

    test("a missing setting falls back rather than being left undefined", async () => {
        await fs.writeFile(path.join(tempDir, CONFIG_PATH), "enabled = true\n", "utf8");

        const result = await readSyncConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.settings.enabled).toBe(true);
        expect(result.settings.onlyOnWifi).toBe(true);
    });

    test("the rendered TOML is what the reader reads back", async () => {
        // buildSyncConfigToml is what a host-side script uses to seed a device's settings, so it has
        // to produce exactly the file the handler would have written.
        const rendered = buildSyncConfigToml({
            settings: {
                enabled: true,
                onlyOnWifi: false,
            },
            pauseBetweenRunsMs: 120000,
        });

        await fs.writeFile(path.join(tempDir, CONFIG_PATH), rendered, "utf8");

        const contents = await readSyncConfigFile(CONFIG_PATH);

        expect(contents.settings.enabled).toBe(true);
        expect(contents.settings.onlyOnWifi).toBe(false);
        expect(contents.pauseBetweenRunsMs).toBe(120000);
    });

    test("a write with no config path fails rather than writing somewhere else", async () => {
        await expect(writeSyncConfigHandler({
            configPath: "",
            settings: {
                enabled: true,
                onlyOnWifi: true,
            },
            pauseBetweenRunsMs: DEFAULT_SYNC_PAUSE_MS,
        }, context)).rejects.toThrow("configPath is required");
    });
});
