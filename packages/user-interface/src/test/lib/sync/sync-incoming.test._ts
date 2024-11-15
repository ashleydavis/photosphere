import { syncIncoming } from "../../../lib/sync/sync-incoming";

describe("sync incoming", () => {
    test("can sync incoming", async () => {
        const setId = "my-set";
        const lastUpdateTime = 10;
        const recordId = "my-record";
        const journalRecords = [
            { 
                collectionName: "my-collection",
                recordId,
                op: { 
                    type: "set", 
                    fields: { name: "Alice" },
                },
            },
        ];
        const api: any = {
            getJournal: jest.fn(async () => ({ journalRecords, latestTime: lastUpdateTime })),
        };
        const mockLastUpdateCollection: any = {
            getOne: jest.fn(async () => ({ lastUpdateTime })),
            setOne: jest.fn(async () => {}),
        };
        const mockCollection: any = {
            getOne: jest.fn(async () => undefined),
            setOne: jest.fn(async () => {}),
        }
        const database: any = {
            collection: (collectionName: string) => {
                if (collectionName === "last-update") {
                    return mockLastUpdateCollection;
                }
                else if (collectionName === "my-collection") {
                    return mockCollection;
                }
                
                throw new Error(`Unexpected collection: ${collectionName}`);
            },
        };
        await syncIncoming({ setIds: [ setId ], api, database });
        expect(api.getJournal).toHaveBeenCalledWith(lastUpdateTime);
        expect(mockLastUpdateCollection.setOne).toHaveBeenCalledWith({ _id: setId, lastUpdateTime });
        expect(mockCollection.setOne).toHaveBeenCalledWith({ _id: recordId, name: "Alice" });
    });
});