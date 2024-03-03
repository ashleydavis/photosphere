import React, { useEffect } from "react";
import { Main } from "user-interface";
import { scanImages } from "./lib/scan";
import { useUpload } from "user-interface/build/context/upload-context";

export function Scan() {

    useEffect(() => {
        scanImages()
            .then(() => console.log('Scanning complete'))
            .catch(error => console.error('Error scanning images', error));
    }, []);

    return (
        <Main />
    );
}