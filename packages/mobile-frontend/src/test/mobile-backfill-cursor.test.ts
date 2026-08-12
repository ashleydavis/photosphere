import { IConfig } from "user-interface";
import { AUTO_IMPORT_BACKFILL_CURSORS_KEY, loadBackfillCursor, saveBackfillCursor } from "../lib/mobile-backfill-cursor";

//
// A config store held in memory, so the cursor bookkeeping can be tested without an app.
//
function makeConfig(initial: Record<string, any>): IConfig {
    const values: Record<string, any> = { ...initial };
    return {
        get: async <ValueType>(key: string): Promise<ValueType | undefined> => values[key],
        set: async (key: string, value: any): Promise<void> => {
            values[key] = value;
        },
    } as IConfig;
}

describe("the mobile backfill cursor", () => {

    test("a database with nothing recorded starts at the beginning of the library", async () => {
        const config = makeConfig({});

        const cursor = await loadBackfillCursor(config, "photosphere-default");

        expect(cursor).toEqual({ pageCursor: undefined, completed: false });
    });

    test("what was recorded is what comes back", async () => {
        const config = makeConfig({});

        await saveBackfillCursor(config, "photosphere-default", { pageCursor: "120", completed: false });

        expect(await loadBackfillCursor(config, "photosphere-default")).toEqual({ pageCursor: "120", completed: false });
    });

    test("a finished walk is recorded as finished", async () => {
        const config = makeConfig({});

        await saveBackfillCursor(config, "photosphere-default", { pageCursor: undefined, completed: true });

        expect(await loadBackfillCursor(config, "photosphere-default")).toEqual({ pageCursor: undefined, completed: true });
    });

    test("each database keeps its own position", async () => {
        const config = makeConfig({});

        await saveBackfillCursor(config, "first", { pageCursor: "10", completed: false });
        await saveBackfillCursor(config, "second", { pageCursor: "90", completed: false });

        expect((await loadBackfillCursor(config, "first")).pageCursor).toBe("10");
        expect((await loadBackfillCursor(config, "second")).pageCursor).toBe("90");
    });

    test("recording one database's position leaves the others alone", async () => {
        const config = makeConfig({});

        await saveBackfillCursor(config, "first", { pageCursor: "10", completed: false });
        await saveBackfillCursor(config, "second", { pageCursor: "90", completed: false });
        await saveBackfillCursor(config, "second", { pageCursor: "100", completed: false });

        expect((await loadBackfillCursor(config, "first")).pageCursor).toBe("10");
        expect((await loadBackfillCursor(config, "second")).pageCursor).toBe("100");
    });

    test("a database that was never recorded starts at the beginning even when others were", async () => {
        const config = makeConfig({});

        await saveBackfillCursor(config, "first", { pageCursor: "10", completed: true });

        expect(await loadBackfillCursor(config, "second")).toEqual({ pageCursor: undefined, completed: false });
    });

    test("a stored value that is not a position starts at the beginning rather than crashing", async () => {
        const config = makeConfig({ [AUTO_IMPORT_BACKFILL_CURSORS_KEY]: { "photosphere-default": "nonsense" } });

        expect(await loadBackfillCursor(config, "photosphere-default")).toEqual({ pageCursor: undefined, completed: false });
    });

    test("a stored position with the wrong field types is read as the beginning", async () => {
        const config = makeConfig({
            [AUTO_IMPORT_BACKFILL_CURSORS_KEY]: { "photosphere-default": { pageCursor: 42, completed: "yes" } },
        });

        expect(await loadBackfillCursor(config, "photosphere-default")).toEqual({ pageCursor: undefined, completed: false });
    });
});
