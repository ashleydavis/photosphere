import { initialSync } from "../../../lib/sync/initial-sync";

describe("initial sync", () => {
    test("can load assets from indexeddb", async () => {
        const asset = { name: "Alice" };
        const database: any = {
            collection: jest.fn(() => ({
                getAllByIndex: jest.fn(async () => [asset]),
            })),
        };
        const api: any = {
            getLatestTime: jest.fn(async () => {}),
            getAll: jest.fn(async () => []),
        };
        const setAssets = jest.fn();
        await initialSync(database, "my-set", api, 0, setAssets);
        expect(setAssets).toHaveBeenCalledWith([asset]);
    });

    test("can load assets from api", async () => {
        const lastUpdateTime = 10;
        const mockMetadataCollection: any = {
            getAllByIndex: async () => [],
            setOne: jest.fn(async () => {}),
        };
        const mockLastUpdateCollection: any = {
            setOne: jest.fn(async () => {}),
        };
        const database: any = {
            collection: (collectionName: string) => {
                if (collectionName === "metadata") {
                    return mockMetadataCollection;
                }
                else if (collectionName === "last-update") {
                    return mockLastUpdateCollection;
                }
                
                throw new Error(`Unexpected collection: ${collectionName}`);

            },
        };
        const mockRecord1 = { name: "Alice" };
        const mockRecord2 = { name: "Bob" };
        const api: any = {
            getLatestTime: jest.fn(async () => lastUpdateTime),
            getAll: jest.fn()
                .mockImplementationOnce(async () => [mockRecord1])
                .mockImplementationOnce(async () => [mockRecord2])
                .mockImplementationOnce(async () => []),
        };
        const setAssets = jest.fn();
        const setId = "my-set";
        await initialSync(database, setId, api, 0, setAssets);

        //
        // Added assets to the UI.
        //
        expect(setAssets).toHaveBeenCalledWith([{ name: "Alice" }]);

        //
        // Add assets to local database.
        //
        expect(mockMetadataCollection.setOne).toHaveBeenCalledWith(mockRecord1);
        expect(mockMetadataCollection.setOne).toHaveBeenCalledWith(mockRecord2);

        //
        // Record the latest update time.
        //
        expect(mockLastUpdateCollection.setOne).toHaveBeenCalledWith({
            _id: setId,
            lastUpdateTime,
        });
    });
});