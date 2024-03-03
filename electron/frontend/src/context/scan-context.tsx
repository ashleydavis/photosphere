//
// This context implements scanning the file system for assets.
//

import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { useUpload } from "user-interface";
import { scanImages as _scanImages } from "../lib/scan";
import fs from "fs";

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

    const { uploadFiles } = useUpload();

    //
    // Scan the file system for assets.
    //
    function scanImages(): void {
        _scanImages(async fileDetails => {
            console.log(`Uploading ${fileDetails.path}`);
            const buffer = await fs.promises.readFile(fileDetails.path);
            const blob = new Blob([buffer], { type: fileDetails.contentType });
            const file = new File([blob], fileDetails.path, { type: fileDetails.contentType });
            await uploadFiles({ files: [ file ] });
        })
        .then(() => console.log('Scanning complete'))
        .catch(error => console.error('Error scanning images', error));

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

