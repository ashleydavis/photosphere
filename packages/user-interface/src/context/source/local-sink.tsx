//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IDatabaseOp } from "defs";
import { IGallerySink } from "../../lib/gallery-sink";
import { IPersistentQueue } from "../../lib/sync/persistent-queue";
import { IAssetUploadRecord } from "../../lib/sync/asset-upload-record";
import { IAssetUpdateRecord } from "../../lib/sync/asset-update-record";
import { IAssetData } from "../../def/asset-data";
import { applyOperations } from "../../lib/apply-operation";
import { IAssetRecord } from "../../def/asset-record";
import { IGalleryItem } from "../../lib/gallery-item";
import { uuid } from "../../lib/uuid";
import dayjs from "dayjs";
import { IDatabase } from "../../lib/database/database";

export interface IProps { 
    //
    // The set id for the assets.
    //
    setId: string | undefined;

    //
    // Queues outgoing asset uploads.
    //
    outgoingAssetUploadQueue: IPersistentQueue<IAssetUploadRecord>;

    //
    // Queues outgoing asset updates.
    //
    outgoingAssetUpdateQueue: IPersistentQueue<IAssetUpdateRecord>;

    //
    // The local indexeddb database.
    //
    database: IDatabase;
};

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ setId, outgoingAssetUploadQueue, outgoingAssetUpdateQueue, database }: IProps): IGallerySink {

    //
    // Adds a new gallery item.
    //
    async function addGalleryItem(galleryItem: IGalleryItem): Promise<void> {
        if (!setId) {
            throw new Error("No set is loaded.");
        }

        const ops: IDatabaseOp[] = [
            {
                collectionName: "metadata",
                recordId: galleryItem._id,
                op: {
                    type: "set",
                    fields: {
                        _id: galleryItem._id,
                        width: galleryItem.width,
                        height: galleryItem.height,
                        origFileName: galleryItem.origFileName,
                        origPath: galleryItem.origPath,
                        contentType: galleryItem.contentType,
                        hash: galleryItem.hash,
                        location: galleryItem.location,
                        fileDate: galleryItem.fileDate,
                        photoDate: galleryItem.photoDate,
                        sortDate: galleryItem.sortDate,
                        uploadDate: dayjs().toISOString(),
                        properties: galleryItem.properties,
                        labels: galleryItem.labels,
                        description: galleryItem.description,
                        setId,
                    },
                },
            }
        ];

        //
        // Updates the local database.
        //
        await applyOperations(database, ops);        

        //
        // Queue the updates for upload to the cloud.
        //
        await outgoingAssetUpdateQueue.add({ 
            ops,
        });       
    }

    //
    // Update a gallery item.
    //
    async function updateGalleryItem(assetId: string, partialGalleryItem: Partial<IGalleryItem>): Promise<void> {
        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            op: {
                type: "set",
                fields: partialGalleryItem,
            },
        }]

        //
        // Updates the local database.
        //
        await applyOperations(database, ops);        

        //
        // Queue the updates for upload to the cloud.
        //
        await outgoingAssetUpdateQueue.add({ 
            ops,
        });
    }

    //
    // Stores an asset.
    //
    async function storeAsset(assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        if (!setId) {
            throw new Error("No set is loaded.");
        }

        // 
        // Store the asset locally.
        //
        await database.collection<IAssetRecord>(assetType).setOne({
            _id: assetId,
            storeDate: new Date(),
            assetData,
        });

        // 
        // Queue the asset for upload to the cloud.
        //
        await outgoingAssetUploadQueue.add({
            setId,
            assetId,
            assetType,
            assetData,
        });
    }

    return {
        addGalleryItem,
        updateGalleryItem,
        storeAsset,
    };
}