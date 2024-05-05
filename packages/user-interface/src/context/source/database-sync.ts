import { useEffect, useRef } from "react";
import { useOnline } from "../../lib/use-online";
import { IAssetUpdateRecord, IAssetUploadRecord } from "./outgoing-queue-sink";
import { openDatabase, getLeastRecentRecord, deleteRecord } from "../../lib/indexeddb";
import { IGallerySink } from "./gallery-sink";
import { useIndexeddb } from "../indexeddb-context";

const SYNC_POLL_PERIOD = 1000;

//
// Periodically synchorize the local database with the cloud database.
//
export function useDatabaseSync({ cloudSink }: { cloudSink: IGallerySink }) {
    
    const { isOnline } = useOnline();
    const { db } = useIndexeddb()

    useEffect(() => {
        let timer: NodeJS.Timeout | undefined = undefined;
       
        if (isOnline) {
            async function sync() {
                timer = undefined;

                try {
                    if (db === undefined) {
                        throw new Error("Database not open");
                    }

                    //
                    // Flush the queue of outgoing asset uploads.
                    //
                    while (true) {
                        const outgoingUpload = await getLeastRecentRecord<IAssetUploadRecord>(db, "outgoing-asset-upload");
                        if (!outgoingUpload) {
                            break;
                        }

                        await cloudSink.uploadAsset(outgoingUpload.assetId, outgoingUpload.assetType, outgoingUpload.contentType, outgoingUpload.data);
                        await deleteRecord(db, "outgoing-asset-upload", outgoingUpload._id);
                    }

                    //
                    // Flush the queue of outoing asset updates.
                    //
                    while (true) {
                        const outgoingUpdate = await getLeastRecentRecord<IAssetUpdateRecord>(db, "outgoing-asset-update");
                        if (!outgoingUpdate) {
                            break;
                        }

                        await cloudSink.updateAsset(outgoingUpdate.assetId, outgoingUpdate.assetUpdate);
                        await deleteRecord(db, "outgoing-asset-update", outgoingUpdate._id);
                    }
                }    
                catch (err) {
                    console.error(`Failed to sync:`);
                    console.error(err);
                }

                timer = setTimeout(sync, SYNC_POLL_PERIOD);
            }

            timer = setTimeout(sync, SYNC_POLL_PERIOD);
        }

        return () => {
            if (timer) {
                clearTimeout(timer);
                timer = undefined;
            }
        };

    }, [isOnline]);
}