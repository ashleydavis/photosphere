import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import { DEFAULT_SYNC_PAUSE_MS } from "api/src/lib/sync-settings";
import { buildConfigYaml, readConfigFromStorage } from "node-api/src/lib/config.worker";
import { planSyncHandler } from "../../lib/plan-sync.worker";

//
// Tests for the task the native background sync asks what to do.
//
// Every way a sync can be refused is a test here, because each one is a promise the app makes: the
// master switch is what a user reaches for when they want syncing to stop, and the Wi-Fi-only
// restriction is what stands between an automatic backup and somebody's mobile data bill. The rule
// itself is computeSyncAllowed and is covered in packages/api; what is covered here is that this task
// reads the right settings, asks the platform for the connection type, and applies that rule rather
// than a second copy of it.
//
// It runs against the real filesystem, from a temporary directory standing in for the app's storage
// sandbox, because reading those files is part of what is under test.
//

//
// The task context the handler takes. It does not use it.
//
const context: any = {};

//
// The database the tests use, which stands in for the one automatic import creates.
//
const DATABASE_PATH = "photosphere-default";

//
// A temporary working directory standing in for the app's storage sandbox, and the directory the
// test switches back to afterwards.
//
let tempDir: string;
let previousCwd: string;

beforeEach(async () => {
    previousCwd = process.cwd();
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-plan-sync-"));
    process.chdir(tempDir);
    setConnectionType("wifi");
});

afterEach(async () => {
    delete (globalThis as any).host;
    process.chdir(previousCwd);
    await fs.rm(tempDir, { recursive: true, force: true });
});

//
// Installs a native host bridge reporting the given connection type, standing in for
// ConnectivityManager on Android and NWPathMonitor on iOS.
//
function setConnectionType(connectionType: string): void {
    (globalThis as any).host = {
        networkConnectionType: () => connectionType,
    };
}

//
// Writes the syncing settings into the temporary sandbox's config.yaml, exactly as the app would.
//
// It reads what is already there and puts back only the syncing section, because the two features
// share one file now: rebuilding the document from the syncing settings alone would delete whatever
// automatic import had been told to watch.
//
async function writeSyncSettings(enabled: boolean, onlyOnWifi: boolean, pauseBetweenRunsMs: number = DEFAULT_SYNC_PAUSE_MS): Promise<void> {
    const { config } = await readConfigFromStorage("config.yaml");
    config.sync = {
        settings: {
            enabled,
            onlyOnWifi,
        },
        databasePath: undefined,
        pauseBetweenRunsMs,
    };
    await fs.writeFile(path.join(tempDir, "config.yaml"), buildConfigYaml(config), "utf8");
}

//
// Writes the automatic import section naming the database background sync falls back to, exactly as
// the app would, leaving the syncing settings as they are.
//
async function writeDefaultDatabase(defaultDatabasePath: string | undefined): Promise<void> {
    const { config } = await readConfigFromStorage("config.yaml");
    config.autoImport = {
        settings: {
            enabled: true,
            sources: [
                {
                    type: "device-album",
                    albumId: "all",
                },
            ],
        },
        defaultDatabasePath,
        pauseBetweenRunsMs: 30000,
    };
    await fs.writeFile(path.join(tempDir, "config.yaml"), buildConfigYaml(config), "utf8");
}

//
// Creates the database directory with a config naming an origin, or with no origin at all.
//
async function writeDatabaseConfig(origin: string | undefined): Promise<void> {
    await fs.mkdir(path.join(tempDir, DATABASE_PATH, ".db"), { recursive: true });
    const config = origin === undefined ? {} : { origin };
    await fs.writeFile(
        path.join(tempDir, DATABASE_PATH, ".db", "config.json"),
        JSON.stringify(config, null, 2),
        "utf8");
}

//
// Sets up everything a sync needs, so a test only has to change the one thing it is about.
//
async function setUpSyncableDatabase(): Promise<void> {
    await writeDefaultDatabase(DATABASE_PATH);
    await writeDatabaseConfig("/somewhere/else/photos");
}

describe("plan-sync", () => {

    test("says not to sync when there is no settings file at all", async () => {
        // A phone whose settings cannot be read must not start pushing photos over whatever
        // connection it happens to have. Off is the only safe reading of a file that is not there.
        await setUpSyncableDatabase();

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.steps).toEqual([]);
    });

    test("says not to sync when syncing is switched off", async () => {
        // The master switch, and the first thing checked: it is what a user reaches for when they
        // want syncing to stop, so nothing else can get past it.
        await writeSyncSettings(false, false);
        await setUpSyncableDatabase();

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.steps).toEqual([]);
    });

    test("says not to sync on a cellular connection when the Wi-Fi-only restriction is on", async () => {
        // Getting this wrong spends somebody's mobile data without asking.
        await writeSyncSettings(true, true);
        await setUpSyncableDatabase();
        setConnectionType("cellular");

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.steps).toEqual([]);
    });

    test("syncs on Wi-Fi when the Wi-Fi-only restriction is on", async () => {
        // Otherwise the restriction would read as "never sync".
        await writeSyncSettings(true, true);
        await setUpSyncableDatabase();
        setConnectionType("wifi");

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(true);
    });

    test("syncs when the connection type is unknown and the Wi-Fi-only restriction is on", async () => {
        // Matching what computeSyncAllowed already does. A platform that cannot tell one connection from
        // another must not be silently stopped, which is what the desktop and the browser report.
        await writeSyncSettings(true, true);
        await setUpSyncableDatabase();
        setConnectionType("unknown");

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(true);
    });

    test("syncs on a cellular connection when the Wi-Fi-only restriction is off", async () => {
        await writeSyncSettings(true, false);
        await setUpSyncableDatabase();
        setConnectionType("cellular");

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(true);
    });

    test("says not to sync when there is no connection", async () => {
        await writeSyncSettings(true, false);
        await setUpSyncableDatabase();
        setConnectionType("none");

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.steps).toEqual([]);
    });

    test("a connection type nobody anticipated is treated as unknown rather than stopping syncing", async () => {
        await writeSyncSettings(true, true);
        await setUpSyncableDatabase();
        setConnectionType("something-new");

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(true);
    });

    test("says not to sync when no default database has been created yet", async () => {
        await writeSyncSettings(true, false);
        await writeDefaultDatabase(undefined);

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.steps).toEqual([]);
    });

    test("says not to sync when the database has no origin to sync to", async () => {
        // The sync task itself would skip it, having paid for an engine slot and a database open to
        // find that out, and it would do so every pass for as long as the phone was switched on.
        await writeSyncSettings(true, false);
        await writeDefaultDatabase(DATABASE_PATH);
        await writeDatabaseConfig(undefined);

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.steps).toEqual([]);
    });

    test("hands back a sync-database step for the default database when a sync should run", async () => {
        // Native code runs this step unchanged and builds no payload of its own, so getting it wrong
        // here is getting the background sync wrong on both platforms at once.
        await writeSyncSettings(true, false);
        await setUpSyncableDatabase();

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(true);
        expect(plan.databasePath).toBe(DATABASE_PATH);
        expect(plan.steps.map(step => step.type)).toEqual(["sync-database"]);
        expect(plan.steps[0].data).toEqual({
            databasePath: DATABASE_PATH,
            // Named here rather than in native code, so a phone's job row reads the same as a
            // desktop's. No cancel source: the pass is queued by the native driver under a source
            // the WebView never learns, so the row must not offer a Cancel button it cannot honour.
            job: {
                id: `sync:${DATABASE_PATH}`,
                name: "Syncing database",
            },
        });
    });

    test("carries the pause through so the loop waits what the settings asked for", async () => {
        await writeSyncSettings(true, false, 90000);
        await setUpSyncableDatabase();

        const plan = await planSyncHandler({}, context);

        expect(plan.pauseBetweenRunsMs).toBe(90000);
    });

    test("a refusal still carries the pause, so the loop does not spin asking again", async () => {
        await writeSyncSettings(false, true);
        await setUpSyncableDatabase();

        const plan = await planSyncHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
    });

    test("a refusal says why, so a phone that is not syncing can be accounted for", async () => {
        await writeSyncSettings(true, true);
        await setUpSyncableDatabase();
        setConnectionType("cellular");

        const plan = await planSyncHandler({}, context);

        expect(plan.reason).toContain("cellular");
    });
});
