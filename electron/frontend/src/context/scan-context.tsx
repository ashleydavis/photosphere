//
// This context implements scanning the file system for assets.
//

import React, { createContext, ReactNode, useContext, useRef, useState } from "react";
import { scanImages as _scanImages, getContentType } from "../lib/scan";
import dayjs from "dayjs";
import { loadFileInfo, loadFileToBlob, loadFileToThumbnail } from "../lib/file";
import { IAsset, IAssetData, IAssetSource, IPage } from "database";

export interface IScanContext extends IAssetSource {
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

    //
    // Scan the file system for assets.
    //
    function scanImages(): void {
        _scanImages(async fileDetails => {
            const { resolution, hash } = await loadFileInfo(fileDetails.path, fileDetails.contentType);
            const newAsset: IAsset = {
                _id: fileDetails.path,
                width: resolution.width,
                height: resolution.height,
                origFileName: fileDetails.path,
                hash,
                fileDate: dayjs().toISOString(),
                sortDate: dayjs().toISOString(),
                uploadDate: dayjs().toISOString(),
            };
            assets.current.push(newAsset);
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
    async function loadAssets(collectionId: string, max: number, next?: string): Promise<IPage<IAsset>> {
        return {
            records: next !== undefined ? assets.current.slice(parseInt(next), assets.current.length) : assets.current,
            next: isScanning.current ? assets.current.length.toString() : undefined,
        };
    }

    //
    // Maps a hash to the assets already uploaded.
    //
    async function mapHashToAssets(collectionId: string, hash: string): Promise<string[]> {
        return [];
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
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
        isInitialised: true,
        scanImages,
        loadAssets,
        mapHashToAssets,
        loadAsset,
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

