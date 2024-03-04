//
// This context implements scanning the file system for assets.
//

import React, { createContext, ReactNode, useContext, useState } from "react";
import { IGalleryItem } from "user-interface";
import { scanImages as _scanImages } from "../lib/scan";
import dayjs from "dayjs";
import fs from "fs";

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
    // Scan the file system for assets.
    //
    function scanImages(): void {
        _scanImages(async fileDetails => {

            const buffer = await fs.promises.readFile(fileDetails.path);
            const blob = new Blob([buffer], { type: fileDetails.contentType });            
            const objectURL = URL.createObjectURL(blob); //todo: At some point this must be revoked.

            const newAsset: IGalleryItem = {
                _id: `local://${fileDetails.path}`,
                width: 100,
                height: 100,
                origFileName: fileDetails.path,
                hash: "ABCD",
                fileDate: dayjs().toISOString(),
                sortDate: dayjs().toISOString(),
                uploadDate: dayjs().toISOString(),
                objectURL,
            };
            setAssets(prev => prev.concat([ newAsset ]));
        })
        .then(() => console.log('Scanning complete'))
        .catch(error => console.error('Error scanning images', error));
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
