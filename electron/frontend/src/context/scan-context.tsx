//
// This context implements scanning the file system for assets.
//

import React, { createContext, ReactNode, useContext, useRef, useState } from "react";
import { scanImages as _scanImages, getContentType } from "../lib/scan";
import dayjs from "dayjs";
import { loadFileInfo, loadFileToBlob, loadFileToThumbnail } from "../lib/file";
import path from "path";
import { IAsset } from "defs";
import { IAssetData, IGalleryItem, IGallerySource, useUpload } from "user-interface";

export interface IScanContext {
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
    // Assets that have been scanned.
    //
    const assets = useRef<IAsset[]>([]);

    //
    // Set to true while scanning.
    //
    const isScanning = useRef<boolean>(true);

    const { queueUpload } = useUpload();

    //
    // Scan the file system for assets.
    //
    function scanImages(): void {
        _scanImages(async fileDetails => {
            const { resolution, hash, fileDate } = await loadFileInfo(fileDetails.path, fileDetails.contentType);
            const newAsset: IAsset = {
                _id: fileDetails.path,
                width: resolution.width,
                height: resolution.height,
                origFileName: fileDetails.path,
                origPath: "",
                contentType: fileDetails.contentType,
                hash,
                fileDate: dayjs(fileDate).toISOString(),
                sortDate: dayjs(fileDate).toISOString(),
                uploadDate: dayjs().toISOString(),
                setId: "this doesn't make sense here"
            };
            assets.current.push(newAsset);

            await queueUpload(
                fileDetails.path,
                () => loadFileToBlob(fileDetails.path, fileDetails.contentType),
                fileDetails.contentType,
                fileDate,
                undefined,
                path.dirname(fileDetails.path).split("/")
            );  
        })
        .then(() => {
            isScanning.current = false;
            console.log('Scanning complete');
        })
        .catch(error => {
            isScanning.current = false;
            console.error('Error scanning images', error);
        });
    }

    //
    // Loads metadata for all assets.
    //
    async function loadGalleryItems(): Promise<IGalleryItem[]> {
        return assets.current;
    }

    //
    // Maps a hash to the assets already uploaded.
    //
    async function checkAssetHash(hash: string): Promise<boolean> {
        return false;
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<IAssetData | undefined> {
        const contentType = getContentType(assetId);
        if (!contentType) {
            throw new Error(`Unknown content type for asset ${assetId}`);
        }

        switch (assetType) {
            case "thumb": {
                return {
                    data: await loadFileToThumbnail(assetId, contentType),
                    contentType: "image/png", // Thumbnail always png.
                };
            }

            case "display": {
                return {
                    data: await loadFileToBlob(assetId, contentType),
                    contentType,
                };
            }

            default: {
                throw new Error(`Unknown asset type ${assetType}`);
            }
        }
    }
        
    const value: IScanContext = {
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

