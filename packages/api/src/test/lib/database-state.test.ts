import { MockStorage } from "storage";
import { IDatabaseState, loadDatabaseState, saveDatabaseState, mergeDatabaseState, updateDatabaseStateLocked } from "api";

const STATE_PATH = ".db/state.dat";
const LOCK_PATH = ".db/write.lock";

describe("database-state", () => {
    test("round-trips all fields", async () => {
        const storage = new MockStorage();
        const state: IDatabaseState = {
            contentHash: Buffer.from("0123456789abcdef0123456789abcdef", "hex"),
            lastModifiedAt: "2026-01-02T03:04:05.000Z",
            lastSyncedAt: "2026-01-02T03:04:06.000Z",
            lastReplicatedAt: "2026-01-02T03:04:07.000Z",
            autoImportBackfillCursor: "/home/someone/Pictures/holiday/IMG_0042.jpg",
            autoImportBackfillCompleted: true,
        };

        await saveDatabaseState(storage, state);
        const loaded = await loadDatabaseState(storage);

        expect(loaded).toEqual(state);
        expect(loaded!.contentHash!.equals(state.contentHash!)).toBe(true);
    });

    test("round-trips a backfill in progress", async () => {
        const storage = new MockStorage();

        await saveDatabaseState(storage, { autoImportBackfillCursor: "/photos/IMG_0007.jpg" });
        const loaded = await loadDatabaseState(storage);

        expect(loaded!.autoImportBackfillCursor).toBe("/photos/IMG_0007.jpg");
        expect(loaded!.autoImportBackfillCompleted).toBeUndefined();
    });

    test("a state with no backfill comes back without one", async () => {
        const storage = new MockStorage();

        await saveDatabaseState(storage, { lastSyncedAt: "2026-01-02T03:04:06.000Z" });
        const loaded = await loadDatabaseState(storage);

        expect(loaded!.autoImportBackfillCursor).toBeUndefined();
        expect(loaded!.autoImportBackfillCompleted).toBeUndefined();
    });

    test("the backfill cursor survives a merge that does not mention it", async () => {
        const storage = new MockStorage();

        await saveDatabaseState(storage, { autoImportBackfillCursor: "/photos/IMG_0007.jpg" });
        await mergeDatabaseState(storage, { lastSyncedAt: "2026-01-02T03:04:06.000Z" });
        const loaded = await loadDatabaseState(storage);

        expect(loaded!.autoImportBackfillCursor).toBe("/photos/IMG_0007.jpg");
        expect(loaded!.lastSyncedAt).toBe("2026-01-02T03:04:06.000Z");
    });

    test("omits absent fields on load", async () => {
        const storage = new MockStorage();

        await saveDatabaseState(storage, { lastSyncedAt: "2026-01-02T03:04:06.000Z" });
        const loaded = await loadDatabaseState(storage);

        expect(loaded).toEqual({ lastSyncedAt: "2026-01-02T03:04:06.000Z" });
        expect(loaded!.contentHash).toBeUndefined();
        expect(loaded!.lastModifiedAt).toBeUndefined();
    });

    test("returns undefined when the file is missing", async () => {
        const storage = new MockStorage();
        expect(await loadDatabaseState(storage)).toBeUndefined();
    });

    test("returns undefined for a zero-byte file", async () => {
        const storage = new MockStorage();
        await storage.write(STATE_PATH, undefined, Buffer.alloc(0));
        expect(await loadDatabaseState(storage)).toBeUndefined();
    });

    test("returns undefined for a garbage file", async () => {
        const storage = new MockStorage();
        await storage.write(STATE_PATH, undefined, Buffer.alloc(20, 0xff));
        expect(await loadDatabaseState(storage)).toBeUndefined();
    });

    test("returns undefined when the checksum does not match", async () => {
        const storage = new MockStorage();
        await saveDatabaseState(storage, { lastModifiedAt: "2026-01-02T03:04:05.000Z" });

        // Flip the last checksum byte so the stored checksum no longer matches the payload.
        const good = await storage.read(STATE_PATH);
        const corrupt = Buffer.from(good!);
        corrupt[corrupt.length - 1] = corrupt[corrupt.length - 1] ^ 0xff;
        await storage.write(STATE_PATH, undefined, corrupt);

        expect(await loadDatabaseState(storage)).toBeUndefined();
    });

    test("mergeDatabaseState merges into an existing state", async () => {
        const storage = new MockStorage();
        await saveDatabaseState(storage, { lastModifiedAt: "A", lastSyncedAt: "B" });

        await mergeDatabaseState(storage, { lastSyncedAt: "C" });

        expect(await loadDatabaseState(storage)).toEqual({ lastModifiedAt: "A", lastSyncedAt: "C" });
    });

    test("mergeDatabaseState creates the state when absent", async () => {
        const storage = new MockStorage();
        await mergeDatabaseState(storage, { lastModifiedAt: "A" });
        expect(await loadDatabaseState(storage)).toEqual({ lastModifiedAt: "A" });
    });

    test("updateDatabaseStateLocked writes while holding the lock, then releases it", async () => {
        const storage = new MockStorage();

        await updateDatabaseStateLocked(storage, "session-1", { lastSyncedAt: "X" });

        expect(await loadDatabaseState(storage)).toEqual({ lastSyncedAt: "X" });
        // The lock is released afterwards, so another owner can acquire it.
        expect(await storage.acquireWriteLock(LOCK_PATH, "other")).toBe(true);
    });

    test("updateDatabaseStateLocked does nothing when the lock is held by another owner", async () => {
        const storage = new MockStorage();
        await storage.acquireWriteLock(LOCK_PATH, "other-owner");

        await updateDatabaseStateLocked(storage, "session-1", { lastSyncedAt: "X" });

        expect(await loadDatabaseState(storage)).toBeUndefined();
    });
});
