import { syncOutgoing } from "../../../lib/sync/sync-outgoing";

describe("sync outgoing", () => {
    test("can sync outgoing upload", async () => {
        const setId = "my-set";
        const assetId = "my-asset";
        const assetType = "thumbnail";
        const assetData = {};
        const outgoingUpdateQueue: any = {
            getNext: jest.fn()
                .mockImplementationOnce(async () => ({ setId, assetId, assetType, assetData }))
                .mockImplementationOnce(async () => undefined),
            removeNext: jest.fn(async () => {}),
        };
        const api: any = {
            uploadSingleAsset: jest.fn(async () => {}),
        };
        await syncOutgoing({ outgoingUpdateQueue, api });
        expect(api.uploadSingleAsset).toHaveBeenCalledWith(setId, assetId, assetType, assetData);
        expect(outgoingUpdateQueue.removeNext).toHaveBeenCalled();
    });

    test("can sync outgoing update", async () => {
        const ops = [{ collectionName: "my-collection", recordId: "my-record" }];
        const outgoingUpdateQueue: any = {
            getNext: jest.fn()
                .mockImplementationOnce(async () => ({ ops }))
                .mockImplementationOnce(async () => undefined),
            removeNext: jest.fn(async () => {}),
        };
        const api: any = {
            submitOperations: jest.fn(async () => {}),
        };
        await syncOutgoing({ outgoingUpdateQueue, api });
        expect(api.submitOperations).toHaveBeenCalledWith(ops);
        expect(outgoingUpdateQueue.removeNext).toHaveBeenCalled();
    });
});