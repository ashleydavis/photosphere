import { promises as fs } from "fs";
import * as os from "os";
import * as path from "path";
import type { ITaskContext } from "task-queue";
import { checkDatabaseExistsHandler } from "../../lib/check-database-exists.worker";

//
// Unit tests for the check-database-exists worker handler.
//
// The handler reuses checkDatabaseExists, which builds FileStorage for the path and checks for the
// database's merkle tree file (.db/files.dat). On device that file access routes through the fs shim's
// fsAccess host function; in this jest env node-api's storage uses the real fs, so the tests drive it
// against a real temp directory. The semantics under test are identical either way: a path with a
// database reads as present, and a directory that exists but holds no database reads as absent.
//
describe("check-database-exists handler", () => {

    //
    // A minimal task context. The handler ignores the context entirely, so the members are no-ops.
    //
    const context: ITaskContext = {
        uuidGenerator: { generate: () => "test-id" },
        timestampProvider: { now: () => 0, dateNow: () => new Date(0) },
        sessionId: "test-session",
        maxConcurrentChildTasks: 10,
        taskId: "test-task",
        sendMessage: () => {},
        isCancelled: () => false,
    };

    let workDir: string;

    beforeEach(async () => {
        workDir = await fs.mkdtemp(path.join(os.tmpdir(), "check-db-exists-"));
    });

    afterEach(async () => {
        await fs.rm(workDir, { recursive: true, force: true });
    });

    test("reports exists=true when the database's merkle tree file is present", async () => {
        const databasePath = path.join(workDir, "real-db");
        await fs.mkdir(path.join(databasePath, ".db"), { recursive: true });
        await fs.writeFile(path.join(databasePath, ".db", "files.dat"), Buffer.from([1, 2, 3]));

        const result = await checkDatabaseExistsHandler({ databasePath }, context);
        expect(result.exists).toBe(true);
    });

    test("reports exists=false when the directory exists but holds no database", async () => {
        const databasePath = path.join(workDir, "empty-dir");
        await fs.mkdir(databasePath, { recursive: true });

        const result = await checkDatabaseExistsHandler({ databasePath }, context);
        expect(result.exists).toBe(false);
    });

    test("reports exists=false when the path does not exist at all", async () => {
        const databasePath = path.join(workDir, "does-not-exist");

        const result = await checkDatabaseExistsHandler({ databasePath }, context);
        expect(result.exists).toBe(false);
    });

    test("throws when no database path is supplied", async () => {
        await expect(checkDatabaseExistsHandler({ databasePath: "" }, context))
            .rejects.toThrow("databasePath is required");
    });
});
