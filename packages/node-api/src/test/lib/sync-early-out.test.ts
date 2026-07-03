import { MockStorage } from "storage";
import { saveDatabaseState } from "api";
import { syncDatabases } from "../../lib/sync";

//
// A stand-in object that throws if any property is accessed. Passed as the asset storages and bson
// databases to prove the early-out returns without touching them.
//
function throwingProxy(label: string): any {
    return new Proxy({}, {
        get() {
            throw new Error(`unexpected access to ${label}`);
        },
    });
}

describe("syncDatabases early-out", () => {
    test("returns synced:false without touching the databases when content hashes match", async () => {
        const sourceRaw = new MockStorage();
        const targetRaw = new MockStorage();
        const contentHash = Buffer.alloc(32, 7);
        await saveDatabaseState(sourceRaw, { contentHash });
        await saveDatabaseState(targetRaw, { contentHash });

        const result = await syncDatabases(
            throwingProxy("sourceAsset"),
            sourceRaw,
            throwingProxy("sourceBson"),
            throwingProxy("targetAsset"),
            targetRaw,
            throwingProxy("targetBson"),
            "session-1"
        );

        expect(result.synced).toBe(false);
    });

    test("proceeds past the early-out when content hashes differ", async () => {
        const sourceRaw = new MockStorage();
        const targetRaw = new MockStorage();
        await saveDatabaseState(sourceRaw, { contentHash: Buffer.alloc(32, 1) });
        await saveDatabaseState(targetRaw, { contentHash: Buffer.alloc(32, 2) });

        // The first thing syncDatabases does after the early-out is flush the source bson database.
        const sentinel = new Error("proceeded past early-out");
        const sourceBson: any = { flush: async () => { throw sentinel; } };

        await expect(syncDatabases(
            throwingProxy("sourceAsset"),
            sourceRaw,
            sourceBson,
            throwingProxy("targetAsset"),
            targetRaw,
            throwingProxy("targetBson"),
            "session-1"
        )).rejects.toBe(sentinel);
    });

    test("proceeds past the early-out when a content hash is missing", async () => {
        const sourceRaw = new MockStorage();
        const targetRaw = new MockStorage();
        await saveDatabaseState(sourceRaw, { contentHash: Buffer.alloc(32, 1) });
        // The target has no state file, so there is no content hash to compare.

        const sentinel = new Error("proceeded past early-out");
        const sourceBson: any = { flush: async () => { throw sentinel; } };

        await expect(syncDatabases(
            throwingProxy("sourceAsset"),
            sourceRaw,
            sourceBson,
            throwingProxy("targetAsset"),
            targetRaw,
            throwingProxy("targetBson"),
            "session-1"
        )).rejects.toBe(sentinel);
    });
});
