import type { ITaskContext } from "task-queue";

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("api/src/lib/database-config", () => ({
    updateDatabaseConfig: jest.fn(),
}));

import { openStorage } from "../../lib/open-storage";
import { updateDatabaseConfig } from "api/src/lib/database-config";
import { setDatabaseOriginHandler } from "../../lib/set-database-origin.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockUpdateDatabaseConfig = updateDatabaseConfig as jest.MockedFunction<typeof updateDatabaseConfig>;

//
// The handler reads nothing from the context, so an empty one is enough to call it.
//
const emptyContext = {} as ITaskContext;

//
// Stands in for the database's unencrypted storage, which is what the config is written through.
//
const rawStorage = { name: "raw" };

describe("setDatabaseOriginHandler", () => {

    beforeEach(() => {
        mockOpenStorage.mockReset();
        mockUpdateDatabaseConfig.mockReset();
        mockOpenStorage.mockResolvedValue({ storage: {}, rawStorage } as any);
    });

    test("writes the origin into the database's own config", async () => {
        await setDatabaseOriginHandler({ databasePath: "photosphere-default", origin: "s3:my-bucket/photos" }, emptyContext);

        expect(mockOpenStorage).toHaveBeenCalledWith("photosphere-default");
        expect(mockUpdateDatabaseConfig).toHaveBeenCalledWith(rawStorage, { origin: "s3:my-bucket/photos" });
    });

    test("an absent origin clears it rather than being ignored", async () => {
        await setDatabaseOriginHandler({ databasePath: "photosphere-default" }, emptyContext);

        expect(mockUpdateDatabaseConfig).toHaveBeenCalledWith(rawStorage, { origin: undefined });
    });

    test("the config is written through the raw storage, so an encrypted database stays readable", async () => {
        await setDatabaseOriginHandler({ databasePath: "photosphere-default", origin: "s3:my-bucket/photos" }, emptyContext);

        // The sync loop reads this config before it has any encryption key, so writing it through the
        // encrypting storage would leave an origin only a key holder could read, and a background
        // pass would decide the database has nowhere to sync to.
        const [storageWrittenThrough] = mockUpdateDatabaseConfig.mock.calls[0];
        expect(storageWrittenThrough).toBe(rawStorage);
    });

    test("a missing database path is refused rather than writing to nowhere", async () => {
        await expect(setDatabaseOriginHandler({ databasePath: "" }, emptyContext))
            .rejects.toThrow("databasePath is required");
        expect(mockOpenStorage).not.toHaveBeenCalled();
        expect(mockUpdateDatabaseConfig).not.toHaveBeenCalled();
    });
});
