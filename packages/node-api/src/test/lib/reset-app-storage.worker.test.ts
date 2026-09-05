import * as fsSync from "fs";
import * as path from "path";
import type { ITaskContext } from "task-queue";
import { createTestTempDir } from "node-utils";
import { resetAppStorageHandler } from "../../lib/reset-app-storage.worker";

//
// The handler reads the app's config and cache directories from the environment, so every test
// points both at directories of its own. This is what keeps the test off the developer's real
// settings and caches, and out of the way of any other run on the machine.
//
describe("resetAppStorageHandler", () => {

    let tempDir: string;
    let originalConfigDir: string | undefined;
    let originalCacheDir: string | undefined;

    beforeEach(() => {
        tempDir = createTestTempDir("reset-app-storage-worker");
        originalConfigDir = process.env.PHOTOSPHERE_CONFIG_DIR;
        originalCacheDir = process.env.PHOTOSPHERE_CACHE_DIR;
    });

    afterEach(() => {
        restoreEnvironmentVariable("PHOTOSPHERE_CONFIG_DIR", originalConfigDir);
        restoreEnvironmentVariable("PHOTOSPHERE_CACHE_DIR", originalCacheDir);
    });

    //
    // Puts an environment variable back the way the test found it, so one test's directories are not
    // still in force for whatever runs next in this file.
    //
    function restoreEnvironmentVariable(name: string, originalValue: string | undefined): void {
        if (originalValue === undefined) {
            delete process.env[name];
        }
        else {
            process.env[name] = originalValue;
        }
    }

    //
    // The task context. The handler uses nothing from it, so this is the minimum that satisfies the
    // type.
    //
    function makeContext(): ITaskContext {
        return {
            uuidGenerator: { generate: () => "test-uuid" },
            timestampProvider: { now: () => 0, dateNow: () => new Date(0) },
            sessionId: "session-1",
            maxConcurrentChildTasks: 1,
            taskId: "reset-task",
            sendMessage: () => { /* nothing listening. */ },
            isCancelled: () => false,
            addTask: () => { throw new Error("The reset does not queue child tasks."); },
            awaitTask: () => { throw new Error("The reset does not queue child tasks."); },
        } as unknown as ITaskContext;
    }

    //
    // Points the app's config and cache directories at the given paths.
    //
    function useDirectories(configDir: string, cacheDir: string): void {
        process.env.PHOTOSPHERE_CONFIG_DIR = configDir;
        process.env.PHOTOSPHERE_CACHE_DIR = cacheDir;
    }

    test("empties the config and cache directories and leaves the directories in place", async () => {
        const configDir = path.join(tempDir, "config");
        const cacheDir = path.join(tempDir, "cache");
        fsSync.mkdirSync(configDir, { recursive: true });
        fsSync.mkdirSync(cacheDir, { recursive: true });
        fsSync.writeFileSync(path.join(configDir, "databases.toml"), "databases = []");
        fsSync.writeFileSync(path.join(configDir, "desktop.toml"), "theme = 'dark'");
        fsSync.writeFileSync(path.join(cacheDir, "hashes.dat"), "hashes");
        useDirectories(configDir, cacheDir);

        const result = await resetAppStorageHandler({}, makeContext());

        expect(fsSync.readdirSync(configDir)).toEqual([]);
        expect(fsSync.readdirSync(cacheDir)).toEqual([]);
        expect(result.entriesRemoved).toBe(3);
        expect(result.directoriesCleared).toEqual([configDir, cacheDir]);
    });

    test("removes nested directory trees", async () => {
        const configDir = path.join(tempDir, "config");
        const cacheDir = path.join(tempDir, "cache");
        fsSync.mkdirSync(path.join(configDir, "a-database", ".db", "bson"), { recursive: true });
        fsSync.mkdirSync(cacheDir, { recursive: true });
        fsSync.writeFileSync(path.join(configDir, "a-database", ".db", "bson", "metadata.bson"), "bytes");
        useDirectories(configDir, cacheDir);

        const result = await resetAppStorageHandler({}, makeContext());

        expect(fsSync.readdirSync(configDir)).toEqual([]);
        expect(result.entriesRemoved).toBe(1);
    });

    test("leaves everything outside the two directories alone", async () => {
        const configDir = path.join(tempDir, "config");
        const cacheDir = path.join(tempDir, "cache");
        const photosDir = path.join(tempDir, "photos");
        fsSync.mkdirSync(configDir, { recursive: true });
        fsSync.mkdirSync(cacheDir, { recursive: true });
        fsSync.mkdirSync(photosDir, { recursive: true });
        fsSync.writeFileSync(path.join(configDir, "databases.toml"), "databases = []");
        fsSync.writeFileSync(path.join(photosDir, "holiday.jpg"), "a photo nobody may delete");
        useDirectories(configDir, cacheDir);

        await resetAppStorageHandler({}, makeContext());

        expect(fsSync.existsSync(path.join(photosDir, "holiday.jpg"))).toBe(true);
    });

    test("empties one directory once when the config and the cache are the same place", async () => {
        // The device case: getConfigDir() and getCacheDir() both answer the app's storage sandbox
        // root, so the same directory is named twice and must be emptied and counted once.
        const sandboxDir = path.join(tempDir, "sandbox");
        fsSync.mkdirSync(sandboxDir, { recursive: true });
        fsSync.writeFileSync(path.join(sandboxDir, "databases.toml"), "databases = []");
        fsSync.mkdirSync(path.join(sandboxDir, "my-photos"), { recursive: true });
        useDirectories(sandboxDir, sandboxDir);

        const result = await resetAppStorageHandler({}, makeContext());

        expect(fsSync.readdirSync(sandboxDir)).toEqual([]);
        expect(result.entriesRemoved).toBe(2);
        expect(result.directoriesCleared).toEqual([sandboxDir]);
    });

    test("succeeds when the directories do not exist yet", async () => {
        const configDir = path.join(tempDir, "never-written-config");
        const cacheDir = path.join(tempDir, "never-written-cache");
        useDirectories(configDir, cacheDir);

        const result = await resetAppStorageHandler({}, makeContext());

        expect(result.entriesRemoved).toBe(0);
    });
});
