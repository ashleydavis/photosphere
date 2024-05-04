import { useEffect, useRef } from "react";
import { useOnline } from "../../lib/use-online";
import { IAssetUpdateRecord, IAssetUploadRecord } from "./outgoing-queue-sink";
import { openDatabase, getLeastRecentRecord, deleteRecord } from "../../lib/indexeddb";
import { IGallerySink } from "./gallery-sink";

const SYNC_POLL_PERIOD = 1000;

//
// Periodically synchorize the local database with the cloud database.
//
export function useDatabaseSync({ cloudSink }: { cloudSink: IGallerySink }) {
    
    const { isOnline } = useOnline();

    const db = useRef<IDBDatabase | undefined>(undefined);

    useEffect(() => {

        async function openDb() {
            db.current = await openDatabase();
        }

        openDb()
            .catch(err => {
                console.error(`Failed to open indexeddb:`);
                console.error(err);
            });

        return () => {
            if (db.current) {
                db.current.close();
                db.current = undefined;
            }
        };
    });

    useEffect(() => {
        let timer: NodeJS.Timeout | undefined = undefined;

        

        if (isOnline) {
            async function sync() {
                timer = undefined;

                try {
                    if (db.current === undefined) {
                        throw new Error("Database not open");
                    }

                    //
                    // Flush the queue of outgoing asset uploads.
                    //
                    while (true) {
                        const outgoingUpload = await getLeastRecentRecord<IAssetUploadRecord>(db.current, "outgoing-asset-upload");
                        if (!outgoingUpload) {
                            break;
                        }

                        await cloudSink.uploadAsset(outgoingUpload.assetId, outgoingUpload.assetType, outgoingUpload.contentType, outgoingUpload.data);
                        await deleteRecord(db.current, "outgoing-asset-upload", outgoingUpload._id);
                    }

                    //
                    // Flush the queue of outoing asset updates.
                    //
                    while (true) {
                        const outgoingUpdate = await getLeastRecentRecord<IAssetUpdateRecord>(db.current, "outgoing-asset-update");
                        if (!outgoingUpdate) {
                            break;
                        }

                        await cloudSink.updateAsset(outgoingUpdate.assetId, outgoingUpdate.assetUpdate);
                        await deleteRecord(db.current, "outgoing-asset-update", outgoingUpdate._id);
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