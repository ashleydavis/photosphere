import { syncOutgoing } from "../../../lib/sync/sync-outgoing";

describe("sync outgoing", () => {
    test("can sync outgoing upload", async () => {
        const setId = "my-set";
        const assetId = "my-asset";
        const assetType = "thumbnail";
        const assetData = {};
        const outgoingAssetUploadQueue: any = {
            getNext: jest.fn()
                .mockImplementationOnce(async () => ({ setId, assetId, assetType, assetData }))
                .mockImplementationOnce(async () => undefined),
            removeNext: jest.fn(async () => {}),
        };
        const outgoingAssetUpdateQueue: any = {
            getNext: async () => undefined,
        };
        const api: any = {
            uploadSingleAsset: jest.fn(async () => {}),
        };
        await syncOutgoing({ outgoingAssetUploadQueue, outgoingAssetUpdateQueue, api });
        expect(api.uploadSingleAsset).toHaveBeenCalledWith(setId, assetId, assetType, assetData);
        expect(outgoingAssetUploadQueue.removeNext).toHaveBeenCalled();
    });

    test("can sync outgoing update", async () => {
        const ops = [{ collectionName: "my-collection", recordId: "my-record" }];
        const outgoingAssetUploadQueue: any = {
            getNext: async () => undefined,
        };
        const outgoingAssetUpdateQueue: any = {
            getNext: jest.fn()
                .mockImplementationOnce(async () => ({ ops }))
                .mockImplementationOnce(async () => undefined),
            removeNext: jest.fn(async () => {}),
        };
        const api: any = {
            submitOperations: jest.fn(async () => {}),
        };
        await syncOutgoing({ outgoingAssetUploadQueue, outgoingAssetUpdateQueue, api });
        expect(api.submitOperations).toHaveBeenCalledWith(ops);
        expect(outgoingAssetUpdateQueue.removeNext).toHaveBeenCalled();
    });
});