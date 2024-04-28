//
// This context implements scanning the file system for assets.
//

import React, { createContext, ReactNode, useContext, useState } from "react";
import { computeHash, IGalleryItem } from "user-interface";
import { scanImages as _scanImages } from "../lib/scan";
import dayjs from "dayjs";
import fs from "fs";
import { getImageResolution, IResolution, loadBlobToDataURL, loadBlobToImage, resizeImage } from "user-interface/build/lib/image";

//
// Size of the thumbnail to generate and display during uploaded.
//
const PREVIEW_THUMBNAIL_MIN_SIZE = 120;

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
    // Assets that have been scanned.
    //
    const [ assets, setAssets ] = useState<IGalleryItem[]>([]);

    //
    // Loads a local file into a blob.
    //
    async function loadFileToBlob(filePath: string, contentType: string): Promise<Blob> {
        const buffer = await fs.promises.readFile(filePath);

        return new Blob([buffer], { type: contentType });
    }

    //
    // Loads a thumbnail from a local file.
    //
    async function loadThumbnail(filePath: string, contentType: string): Promise<{ thumbnail: string, resolution: IResolution, hash: string }> {
        const blob = await loadFileToBlob(filePath, contentType);
        const image = await loadBlobToImage(blob);
        return {
            thumbnail: resizeImage(image, PREVIEW_THUMBNAIL_MIN_SIZE),
            resolution: getImageResolution(image),
            hash: await computeHash(blob),
        };
    }

    //
    // Loads the full resolution version of a local file.
    //
    async function loadHighRes(filePath: string, contentType: string): Promise<string> {
        const blob = await loadFileToBlob(filePath, contentType);
        return loadBlobToDataURL(blob);
    }   

    //
    // Scan the file system for assets.
    //
    function scanImages(): void {
        //
        //todo: This will be a bit different using local storage.
        //
        //
        // _scanImages(async fileDetails => {
        //     const { thumbnail, resolution, hash } = await loadThumbnail(fileDetails.path, fileDetails.contentType);
        //     const newAsset: IGalleryItem = {
        //         _id: `local://${fileDetails.path}`,
        //         width: resolution.width,
        //         height: resolution.height,
        //         origFileName: fileDetails.path,
        //         hash,
        //         fileDate: dayjs().toISOString(),
        //         sortDate: dayjs().toISOString(),
        //         uploadDate: dayjs().toISOString(),
        //         url: thumbnail,
        //         makeFullUrl: async () => {
        //             return await loadHighRes(fileDetails.path, fileDetails.contentType);
        //         },
        //     };
        //     setAssets(prev => prev.concat([ newAsset ]));
        // })
        // .then(() => console.log('Scanning complete'))
        // .catch(error => console.error('Error scanning images', error));
    }

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

