import type { ITaskContext } from "task-queue";

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("../../lib/import-record-storage", () => ({
    loadImportRecord: jest.fn(),
}));

import { openStorage } from "../../lib/open-storage";
import { loadImportRecord } from "../../lib/import-record-storage";
import { getImportRecordHandler } from "../../lib/get-import-record.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockLoadImportRecord = loadImportRecord as jest.MockedFunction<typeof loadImportRecord>;

//
// The handler reads nothing from the context, so an empty one is enough to call it.
//
const emptyContext = {} as ITaskContext;

describe("getImportRecordHandler", () => {

    beforeEach(() => {
        mockOpenStorage.mockReset();
        mockLoadImportRecord.mockReset();
        mockOpenStorage.mockResolvedValue({ storage: {}, rawStorage: {} } as any);
    });

    test("returns what the database recorded", async () => {
        mockLoadImportRecord.mockResolvedValue({
            entries: [{ assetId: "a", logicalPath: "one.png", outcome: "imported", importedAt: "", source: "automatic" }],
            truncated: true,
        });

        const record = await getImportRecordHandler({ databasePath: "db" }, emptyContext);

        expect(record.entries).toHaveLength(1);
        expect(record.entries[0].source).toBe("automatic");
        expect(record.truncated).toBe(true);
    });

    test("a database that has imported nothing comes back empty rather than failing", async () => {
        mockLoadImportRecord.mockResolvedValue({ entries: [], truncated: false });

        const record = await getImportRecordHandler({ databasePath: "db" }, emptyContext);

        expect(record.entries).toEqual([]);
    });

    test("a missing database path is refused rather than read as an empty database", async () => {
        await expect(getImportRecordHandler({ databasePath: "" }, emptyContext))
            .rejects.toThrow("databasePath is required");
        expect(mockOpenStorage).not.toHaveBeenCalled();
    });
});
