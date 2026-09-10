import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import { DEFAULT_SYNC_PAUSE_MS } from "api/src/lib/sync-settings";
import { buildConfigYaml, readConfigFromStorage } from "node-api/src/lib/config.worker";
import { saveMerkleTree } from "node-api/src/lib/tree";
import { openStorage } from "node-api/src/lib/open-storage";
import { buildMerkleTree, createTree } from "merkle-tree";
import { planPrefetchHandler } from "../../lib/plan-prefetch.worker";

//
// Tests for the task the native background prefetch asks what to do.
//
// Every way a pass can be refused is a test here, because each one is a promise the app makes. The
// prefetch fetches from the origin over the user's connection, so it obeys the same settings the
// sync does: the master switch is what a user reaches for when they want the app to stop using their
// data for a database, and the Wi-Fi-only restriction is what stands between filling a replica in and
// somebody's mobile data bill. The rule itself is computeSyncAllowed and is covered in packages/api;
// what is covered here is that this task reads the right settings, asks the platform for the
// connection type, and applies that rule rather than a second copy of it.
//
// It runs against the real filesystem, from a temporary directory standing in for the app's storage
// sandbox, because reading those files (the settings, the database's config, and the merkle tree that
// says whether the replica is partial) is part of what is under test.
//

//
// The task context the handler takes. It does not use it.
//
const context: any = {};

//
// The database the tests use, which stands in for the replica a phone holds.
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
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-plan-prefetch-"));
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
// Writes the syncing settings into the temporary sandbox's config.yaml, exactly as the app would,
// putting back only the syncing section so whatever automatic import was told to watch survives.
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
// Writes the automatic import section naming the database the prefetch falls back to, leaving the
// syncing settings as they are.
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
// Writes the database's merkle tree, saying whether the replica is partial.
//
// Written as a real tree through the real saver rather than as a hand-made file, because the flag is
// read back by isDatabasePartial through the real loader: a file this test wrote by hand would prove
// the two agreed with each other and nothing about whether either agrees with the app.
//
async function writeMerkleTree(isPartial: boolean): Promise<void> {
    await fs.mkdir(path.join(tempDir, DATABASE_PATH, ".db"), { recursive: true });
    const { storage } = await openStorage(DATABASE_PATH);
    // A real UUID, because the tree is serialized by the real saver and it writes the id as sixteen
    // bytes rather than as text.
    const tree = createTree<any>("6f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d");
    tree.databaseMetadata = { isPartial };
    tree.merkle = buildMerkleTree(tree.sort);
    await saveMerkleTree(tree, storage);
}

//
// Sets up everything a prefetch pass needs, so a test only has to change the one thing it is about.
//
async function setUpPartialReplica(): Promise<void> {
    await writeDefaultDatabase(DATABASE_PATH);
    await writeDatabaseConfig("/somewhere/else/photos");
    await writeMerkleTree(true);
}

describe("plan-prefetch", () => {

    test("says not to run when there is no settings file at all", async () => {
        // A phone whose settings cannot be read must not start pulling files over whatever connection
        // it happens to have. Off is the only safe reading of a file that is not there.
        await setUpPartialReplica();

        const plan = await planPrefetchHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.steps).toEqual([]);
    });

    test("says not to run when syncing is switched off", async () => {
        // The master switch, and the first thing checked. The prefetch has none of its own on purpose:
        // a user who switches syncing off means stop using my data for this database, and there is no
        // reading of that where filling the replica in is still wanted.
        await writeSyncSettings(false, false);
        await setUpPartialReplica();

        const plan = await planPrefetchHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.reason).toContain("switched off");
        expect(plan.steps).toEqual([]);
    });

    test("says not to run on a cellular connection when the Wi-Fi-only restriction is on", async () => {
        // A replica of a real library is thousands of thumbnails. Getting this wrong spends
        // somebody's mobile data without asking.
        await writeSyncSettings(true, true);
        await setUpPartialReplica();
        setConnectionType("cellular");

        const plan = await planPrefetchHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.reason).toContain("cellular");
        expect(plan.steps).toEqual([]);
    });

    test("runs on Wi-Fi when the Wi-Fi-only restriction is on", async () => {
        await writeSyncSettings(true, true);
        await setUpPartialReplica();
        setConnectionType("wifi");

        const plan = await planPrefetchHandler({}, context);

        expect(plan.shouldRun).toBe(true);
    });

    test("says not to run when no database has been opened", async () => {
        await writeSyncSettings(true, false);
        await writeDefaultDatabase(undefined);

        const plan = await planPrefetchHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.reason).toContain("no database");
        expect(plan.steps).toEqual([]);
    });

    test("says not to run when the database has no origin to fill in from", async () => {
        await writeSyncSettings(true, false);
        await writeDefaultDatabase(DATABASE_PATH);
        await writeDatabaseConfig(undefined);
        await writeMerkleTree(true);

        const plan = await planPrefetchHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.reason).toContain("no origin");
        expect(plan.steps).toEqual([]);
    });

    test("says not to run when the database is not a partial replica", async () => {
        // A full database has nothing missing. The prefetch task checks this too and returns, but it
        // would pay for an engine slot and a merkle tree load to find out, every pass, for as long as
        // the phone was switched on.
        await writeSyncSettings(true, false);
        await writeDefaultDatabase(DATABASE_PATH);
        await writeDatabaseConfig("/somewhere/else/photos");
        await writeMerkleTree(false);

        const plan = await planPrefetchHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.reason).toContain("not a partial replica");
        expect(plan.steps).toEqual([]);
    });

    test("hands back a prefetch-database step for the database when a pass should run", async () => {
        // Native code runs this step unchanged and builds no payload of its own, so getting it wrong
        // here is getting the background prefetch wrong on both platforms at once.
        await writeSyncSettings(true, false);
        await setUpPartialReplica();

        const plan = await planPrefetchHandler({}, context);

        expect(plan.shouldRun).toBe(true);
        expect(plan.databasePath).toBe(DATABASE_PATH);
        expect(plan.steps.map(step => step.type)).toEqual(["prefetch-database"]);
        expect(plan.steps[0].data).toEqual({
            databasePath: DATABASE_PATH,
            // No cancel source: the pass is queued by the native driver under a source the WebView
            // never learns, so the row must not offer a Cancel button it cannot honour.
            job: {
                id: `prefetch:${DATABASE_PATH}`,
                name: "Filling in this database",
            },
        });
    });

    test("carries the pause through so the loop waits what the sync settings asked for", async () => {
        // The same gap the sync uses, so no new configuration key exists to be kept in step.
        await writeSyncSettings(true, false, 90000);
        await setUpPartialReplica();

        const plan = await planPrefetchHandler({}, context);

        expect(plan.pauseBetweenRunsMs).toBe(90000);
    });

    test("a refusal still carries the pause, so the loop does not spin asking again", async () => {
        await writeSyncSettings(false, true);
        await setUpPartialReplica();

        const plan = await planPrefetchHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
    });
});
