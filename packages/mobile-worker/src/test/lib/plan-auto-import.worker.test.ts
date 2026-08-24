import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import { DEFAULT_AUTO_IMPORT_PAUSE_MS, DEFAULT_DATABASE_FOLDER_NAME } from "api/src/lib/auto-import-mobile";
import { AUTO_IMPORT_CONFIG_PATH } from "api/src/lib/mobile-config-paths";
import { buildAutoImportConfigToml } from "node-api/src/lib/auto-import-config.worker";
import { planAutoImportHandler, type IAutoImportPassStep } from "../../lib/plan-auto-import.worker";

//
// Tests for the task the native background import asks what to do.
//
// The deciding itself (whether to run, which database, what to watch) is planMobileAutoImport and is
// covered in packages/api. What is covered here is the task around it: that it reads the settings
// from the file rather than from anywhere else, and that the steps it hands back are the tasks a pass
// actually has to run. Native code runs those steps unchanged and builds no payload of its own, so
// getting them wrong here is getting the background import wrong on both platforms at once.
//
// It runs against the real filesystem, from a temporary directory standing in for the app's storage
// sandbox, because reading that file is the part of the task under test.
//

//
// The task context the handler takes. It uses the uuid generator for the import's session id.
//
const context: any = {
    uuidGenerator: {
        generate: () => "test-session-id",
    },
};

//
// A temporary working directory standing in for the app's storage sandbox, and the directory the
// test switches back to afterwards.
//
let tempDir: string;
let previousCwd: string;

beforeEach(async () => {
    previousCwd = process.cwd();
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-plan-auto-import-"));
    process.chdir(tempDir);
});

afterEach(async () => {
    process.chdir(previousCwd);
    await fs.rm(tempDir, { recursive: true, force: true });
});

//
// Writes an auto-import.toml into the temporary sandbox, exactly as the app would.
//
async function writeSettingsFile(enabled: boolean, defaultDatabasePath: string | undefined, sources: any[], pauseBetweenRunsMs: number): Promise<void> {
    const contents = buildAutoImportConfigToml({
        settings: {
            enabled,
            sources,
            backfillItemsPerMinute: 60,
        },
        defaultDatabasePath,
        pauseBetweenRunsMs,
    });
    await fs.writeFile(path.join(tempDir, AUTO_IMPORT_CONFIG_PATH), contents, "utf8");
}

//
// The data of the one step with the given type, so a test can assert on what a task is queued with.
//
function stepData(steps: IAutoImportPassStep[], type: string): any {
    const step = steps.find(candidate => candidate.type === type);
    return step ? step.data : undefined;
}

describe("plan-auto-import", () => {

    test("says not to run when there is no settings file at all", async () => {
        // A phone that has never switched automatic import on. Nothing must run, and nothing must be
        // handed back for the service to run either.
        const plan = await planAutoImportHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.steps).toEqual([]);
    });

    test("says not to run when the settings say off", async () => {
        await writeSettingsFile(false, "photosphere-default", [{ type: "device-album", albumId: "all" }], 5000);

        const plan = await planAutoImportHandler({}, context);

        expect(plan.shouldRun).toBe(false);
        expect(plan.steps).toEqual([]);
    });

    test("creates and records the default database when there is not one yet", async () => {
        await writeSettingsFile(true, undefined, [{ type: "device-album", albumId: "all" }], 5000);

        const plan = await planAutoImportHandler({}, context);

        expect(plan.shouldRun).toBe(true);
        expect(plan.isNewDefault).toBe(true);
        expect(plan.databasePath).toBe(DEFAULT_DATABASE_FOLDER_NAME);
        expect(plan.steps.map(step => step.type)).toEqual([
            "create-database",
            "record-default-database",
            "import-assets",
        ]);
        expect(stepData(plan.steps, "create-database")).toEqual({ databasePath: DEFAULT_DATABASE_FOLDER_NAME });
        expect(stepData(plan.steps, "record-default-database")).toEqual({ databasePath: DEFAULT_DATABASE_FOLDER_NAME });
    });

    test("records the database before importing into it", async () => {
        // Recorded first rather than last, because an import that fails must not leave the next pass
        // creating the database a second time on top of the one that is already there.
        await writeSettingsFile(true, undefined, [{ type: "device-album", albumId: "all" }], 5000);

        const plan = await planAutoImportHandler({}, context);

        const recordIndex = plan.steps.findIndex(step => step.type === "record-default-database");
        const importIndex = plan.steps.findIndex(step => step.type === "import-assets");
        expect(recordIndex).toBeGreaterThanOrEqual(0);
        expect(importIndex).toBeGreaterThanOrEqual(0);
        expect(recordIndex).toBeLessThan(importIndex);
    });

    test("imports straight into the chosen database once there is one", async () => {
        await writeSettingsFile(true, "my-photos", [{ type: "device-album", albumId: "all" }], 5000);

        const plan = await planAutoImportHandler({}, context);

        expect(plan.isNewDefault).toBe(false);
        expect(plan.databasePath).toBe("my-photos");
        expect(plan.steps.map(step => step.type)).toEqual(["import-assets"]);
    });

    test("passes the configured places to watch through to the import", async () => {
        await writeSettingsFile(
            true,
            "my-photos",
            [
                { type: "device-album", albumId: "holiday-album" },
                { type: "device-album", albumId: "pets" },
            ],
            5000);

        const plan = await planAutoImportHandler({}, context);

        expect(plan.settings.sources).toEqual([
            { type: "device-album", albumId: "holiday-album" },
            { type: "device-album", albumId: "pets" },
        ]);
        expect(stepData(plan.steps, "import-assets").options.sources).toEqual([
            { type: "device-album", albumId: "holiday-album" },
            { type: "device-album", albumId: "pets" },
        ]);
    });

    test("watches the whole photo library when no album has been chosen", async () => {
        // Running with no sources at all would import nothing while looking like it was working,
        // which is the worst of both.
        await writeSettingsFile(true, "my-photos", [], 5000);

        const plan = await planAutoImportHandler({}, context);

        expect(plan.shouldRun).toBe(true);
        expect(stepData(plan.steps, "import-assets").options.sources).toEqual([
            { type: "device-album", albumId: "all" },
        ]);
    });

    test("the import step is a real automatic import into the planned database", async () => {
        await writeSettingsFile(true, "my-photos", [{ type: "device-album", albumId: "all" }], 5000);

        const plan = await planAutoImportHandler({}, context);
        const importData = stepData(plan.steps, "import-assets");

        expect(importData.paths).toEqual([]);
        expect(importData.storageDescriptor).toEqual({ databasePath: "my-photos" });
        expect(importData.dryRun).toBe(false);
        expect(importData.sessionId).toBe("test-session-id");
        expect(importData.options.auto).toBe(true);
        expect(importData.options.backfillItemsPerMinute).toBe(60);
    });

    test("carries the gap between passes from the settings file", async () => {
        await writeSettingsFile(true, "my-photos", [{ type: "device-album", albumId: "all" }], 1500);

        const plan = await planAutoImportHandler({}, context);

        expect(plan.pauseBetweenRunsMs).toBe(1500);
    });

    test("a gap of zero in the file falls back to the default rather than spinning", async () => {
        await fs.writeFile(
            path.join(tempDir, AUTO_IMPORT_CONFIG_PATH),
            "enabled = true\ndefault_database_path = \"my-photos\"\npause_between_runs_ms = 0\n",
            "utf8");

        const plan = await planAutoImportHandler({}, context);

        expect(plan.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });
});
