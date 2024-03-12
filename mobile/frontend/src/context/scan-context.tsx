//
// This context implements scanning the file system for assets.
//

import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem, sleep } from "user-interface";
import dayjs from "dayjs";
import { registerPlugin } from '@capacitor/core';

const FileUploader = registerPlugin<any>('FileUploader'); //TODO: Type me.

export interface IScanContext {

    //
    // Assets that have been scanned.
    //
    assets: IGalleryItem[];

    //
    // Scan the file system for assets.
    //
    scanImages(): void;
}

const ScanContext = createContext<IScanContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function ScanContextProvider({ children }: IProps) {

    //
    // Assets that have already been seen indexed by path.
    //
    const assetMap = useRef(new Map<string, IGalleryItem>());

    //
    // Set to true while syncing assets.
    //
    const syncingAssets = useRef(false);

    //
    // Assets that have been scanned.
    //
    const [ assets, setAssets ] = useState<IGalleryItem[]>([]);

    //
    // Scan the file system for assets.
    //
    async function scanImages(): Promise<void> {
        const backend = process.env.BASE_URL;
        if (!backend) {
            throw new Error(`BASE_URL environment variable should be set.`);
        }
        else {
            console.log(`BASE_URL environment variable is set to ${backend}`);
        }
    
        await FileUploader.updateSettings({
            backend: backend,
        });

        const { syncing } = FileUploader.checkSyncStatus();
        if (syncing) {
            console.log(`Already syncing.`);
            return;
        }
    
        const { havePermissions } = await FileUploader.checkPermissions();
        if (!havePermissions) {
            await FileUploader.requestPermissions();
            const { havePermissions } = await FileUploader.checkPermissions();
            if (!havePermissions) {
                return;
            }
        }

        console.log(`Staring the sync.`);
    
        await FileUploader.startSync();
    }

    useEffect(() => {
        const interval = setInterval(() => {
            if (syncingAssets.current) {
                return;
            }

            syncingAssets.current = true;

            FileUploader.getFiles()
                .then(async ({ files }: { files: any[] }) => { //todo:
                    for (const file of files) {
                        if (assetMap.current.has(file.path)) {
                            continue;
                        }

                        const { thumbnail, width, height, hash } = await FileUploader.loadThumbnail({ path: file.path });
                        const dataURL = `data:${file.contentType};base64,${thumbnail}`;
                        const newAsset: IGalleryItem = {
                            _id: `local://${file.path}`,
                            width,
                            height,
                            origFileName: file.path,
                            hash,
                            fileDate: dayjs().toISOString(),
                            sortDate: dayjs().toISOString(),
                            uploadDate: dayjs().toISOString(),
                            url: dataURL,
                            makeFullUrl: async () => {
                                const { fullImage } = await FileUploader.loadFullImage({ path: file.path });
                                const dataURL = `data:${file.contentType};base64,${fullImage}`;
                                return dataURL;
                            },
                        };

                        assetMap.current.set(file.path, newAsset);
                        setAssets(prev => prev.concat([ newAsset ]));
                    }

                    syncingAssets.current = false;
                })
                .catch((err: any) => {
                    console.error(`Failed with error:`);
                    console.error(err);

                    syncingAssets.current = false;
                });

        }, 250);

        return () => {
            clearInterval(interval);
        };

    }, []);

    const value: IScanContext = {
        assets,
        scanImages,
    };

    return (
        <ScanContext.Provider value={value} >
            {children}
        </ScanContext.Provider>
    );
}

//
// Use the scan context in a component.
//
export function useScan(): IScanContext {
    const context = useContext(ScanContext);
    if (!context) {
        throw new Error(`Scan context is not set! Add ScanContextProvider to the component tree.`);
    }
    return context;
}

