import React, { useEffect } from "react";
import { Main } from "user-interface";
import { scanImages } from "./lib/scan";
import { useUpload } from "user-interface/build/context/upload-context";
import fs from "fs";

export function Scan() {

    const { uploadFiles } = useUpload();

    useEffect(() => {
        scanImages(async fileDetails => {
                console.log(`Uploading ${fileDetails.path}`);
                const buffer = await fs.promises.readFile(fileDetails.path);
                const blob = new Blob([buffer], { type: fileDetails.contentType });
                const file = new File([blob], fileDetails.path, { type: fileDetails.contentType });
                await uploadFiles({ files: [ file ] });
            })
            .then(() => console.log('Scanning complete'))
            .catch(error => console.error('Error scanning images', error));
    }, []);

    return (
        <Main />
    );
}