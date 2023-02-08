import React, { useState, DragEvent, useEffect } from "react";
import { getExifData, getImageResolution, resizeImage } from "../lib/image";
import { useApi } from "../context/api-context";
import { computeHash, loadDataURL } from "../lib/file";
import { convertExifCoordinates, reverseGeocode } from "../lib/reverse-geocode";
import { IUploadDetails, UploadState } from "../lib/upload-details";
import { Spinner } from "../components/spinner";

import dayjs from "dayjs";
import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

export function UploadPage() {

    //
    // Interface to the API.
    //
    const api = useApi();
    
    //
    // Set to true when something is dragged over the upload area.
    //
    const [dragOver, setDragOver] = useState<boolean>(false);

    //
    // List of uploads in progress.
    //
    const [uploads, setUploads] = useState<IUploadDetails[]>([]);

    //
    // Counts the number of scans for assets that are currently in progress.
    //
    const [numScans, setNumScans] = useState<number>(0);

    //
    // Set to true when currenlty uploading.
    //
    const [isUploading, setIsUploading] = useState<boolean>(false);

    //
    // Number of assets that have been uploaded so far.
    //
    const [numUploaded, setNumUploaded] = useState<number>(0);

    //
    // The upload we are currently working on.
    //
    const [uploadIndex, setUploadIndex] = useState<number>(0);

    useEffect(() => {
        
        console.log(`Now have ${uploads.length} uploads.`);
        console.log(`Starting next upload ${uploadIndex}.`);

        doNextUpload();

    }, [uploads, uploadIndex]);

    //
    // Do an partial update of an existing upload.
    //
    function updateUpload(uploadUpdate: Partial<IUploadDetails>, uploadIndex: number): void {
        setUploads(uploads => ([
            ...uploads.slice(0, uploadIndex),
            
            // New upload.
            {
                ...uploads[uploadIndex],
                ...uploadUpdate
            },
            
            ...uploads.slice(uploadIndex + 1)
        ]));
    }

    //
    // Sets the state of a particular upload.
    //
    function setUploadStatus(status: UploadState, uploadIndex: number): void {
        updateUpload({ status }, uploadIndex);
    }
    
    //
    // Triggers the next upload from the queue.
    //
    async function doNextUpload() {
        if (isUploading) {
            // Already uploading.
            console.log(`Already uploading.`);
            return;
        }

        // Skip to the next pending asset.
        while (uploadIndex < uploads.length) {
            if (uploads[uploadIndex].status === "pending") {
                // Found it.
                break;
            }
        }

        if (uploadIndex >= uploads.length) { 
            // Nothing to upload. We reached the end of the queue.
            console.log(`No more uploads.`);
            return;
        }

        console.log(`Triggering upload for next pending asset ${uploadIndex}.`);

        setIsUploading(true);

        const nextUpload = uploads[uploadIndex];

        try {
            console.log(`Uploading ${nextUpload.file.name}`);

            //
            // This asset is not yet uploaded.
            //
            setUploadStatus("uploading", uploadIndex);

            const assetId = await api.uploadAsset(nextUpload);

            console.log(`Uploaded ${assetId}`);

            //
            // Update upload state.
            //
            updateUpload({ status: "uploaded", assetId }, uploadIndex);

            //
            // Increment the number uploaded.
            //
            setNumUploaded(numUploaded + 1);

            //
            // Move onto the next upload.
            //
            setUploadIndex(uploadIndex + 1);
        }
        catch (error) {
            console.error(`An upload failed.`);
            console.error(error);
        }
        finally {
            setIsUploading(false);
        }
    }

    //
    // Uploads a single asset.
    //
    async function uploadFile(file: File) {
        const hash = await computeHash(file);
        const existingAssetId = await api.checkAsset(hash);
        if (existingAssetId) {
            console.log(`Already uploaded ${file.name} with hash ${hash}, uploaded to ${existingAssetId}`);

            setNumUploaded(numUploaded + 1);
        }

        console.log(`Queueing ${file.name}`);

        const imageData = await loadDataURL(file);
        const imageResolution = await getImageResolution(imageData);
        const thumbnailDataUrl = await resizeImage(imageData, 100);
        const thumContentTypeStart = 5;
        const thumbContentTypeEnd = thumbnailDataUrl.indexOf(";", thumContentTypeStart);
        const thumbContentType = thumbnailDataUrl.slice(thumContentTypeStart, thumbContentTypeEnd);
        const thumbnailData = thumbnailDataUrl.slice(thumbContentTypeEnd + 1 + "base64,".length);
        const exif = await getExifData(file);

        const uploadDetails: IUploadDetails = {
            file: file,
            resolution: imageResolution,
            thumbnailDataUrl: thumbnailDataUrl,
            thumbnail: thumbnailData,
            thumbContentType: thumbContentType,
            hash: hash,
            status: existingAssetId ? "already-uploaded" : "pending",
            fileDate: dayjs(file.lastModified).toISOString(),
        };

        if (exif) {
            uploadDetails.properties = {
                exif: exif,
            };

            if (exif.GPSLatitude && exif.GPSLongitude) {
                uploadDetails.location = await reverseGeocode(convertExifCoordinates(exif));
            }

            const dateFields = ["DateTime", "DateTimeOriginal", "DateTimeDigitized"];
            for (const dateField of dateFields) {
                const dateStr = exif[dateField];
                if (dateStr) {
                    try {
                        uploadDetails.photoDate = dayjs(dateStr, "YYYY:MM:DD HH:mm:ss").toISOString();
                    }
                    catch (err) {
                        console.error(`Failed to parse date from ${dateStr}`);
                        console.error(err);
                    }
                }
            }
        }

        setUploads(uploads => [ ...uploads, uploadDetails ]);

        console.log(`Queued ${file.name}`);
    }

    //
    // Gets a file from a file system entry.
    //
    function getFile(item: FileSystemFileEntry): Promise<File> {
        return new Promise<File>((resolve, reject) => {
            item.file(resolve, reject);
        })
    }

    //
    // Reads the entries in a directory.
    //
    function readDirectory(reader: FileSystemDirectoryReader): Promise<FileSystemEntry[]> {
        return new Promise<FileSystemEntry[]>((resolve, reject) => {
            reader.readEntries(resolve, reject);
        });
    }

    //
    // Traverses the file system for files.
    //
    // https://protonet.com/blog/html5-drag-drop-files-and-folders/
    //
    async function traverseFileSystem(item: FileSystemEntry): Promise<void> {
        if (item.isFile) {
            // https://developer.mozilla.org/en-US/docs/Web/API/FileSystemEntry
            const file = await getFile(item as FileSystemFileEntry);
            await uploadFile(file);
        }
        else if (item.isDirectory) {
            // https://developer.mozilla.org/en-US/docs/Web/API/FileSystemDirectoryEntry
            const reader = (item as FileSystemDirectoryEntry).createReader();
            let entries: FileSystemEntry[] = [];
            while (true) {
                const newEntries = await readDirectory(reader);
                if (newEntries.length === 0) {
                    break;
                }
                entries = entries.concat(newEntries);
            }

            for (const entry of entries) {
                await traverseFileSystem(entry);
            }
        }
    }

    //
    // Uploads a collection of files.
    //
    // https://developer.mozilla.org/en-US/docs/Web/API/DataTransferItem
    //
    async function onUploadFiles(dataTransfer: { items?: DataTransferItemList, files?: FileList }) {
		setNumScans(numScans + 1);

        try {
	        if (dataTransfer.items) {
	            //
	            // Files (or directories) have been dropped.
	            //
	            // Capture to an array so that we don't lose the items through the subsequent async operations.
	            // Without this, after the first async traversal, there appears to be no items after the first one.
	            //
	            const items = Array.from(dataTransfer.items); 
	            const entries = items.map(item => item.webkitGetAsEntry());
	
	            for (const entry of entries) {
	                if (entry) {
	                    await traverseFileSystem(entry);
	                }
	            }
	        }
	        else if (dataTransfer.files) {
	            //
	            // Files were dropped or selected.
	            // 
	            // The array copy here may not be needed, but I've included just to be on the safe side consdering
	            // the problem documented in the code block above.
	            //
	            const files = Array.from(dataTransfer.files);
	            if (files) {
	                for (const file of files) {
	                    await uploadFile(file);
	                }
	            }
	        }
	    }
        finally {
            setNumScans(numScans - 1);
        }
    }

    function onDragEnter(event: DragEvent<HTMLDivElement>) {

        setDragOver(true);

        event.preventDefault();
        event.stopPropagation();
    }

    function onDragLeave(event: DragEvent<HTMLDivElement>) {

        setDragOver(false);

        event.preventDefault();
        event.stopPropagation();
    }

    function onDragOver(event: DragEvent<HTMLDivElement>) {

        setDragOver(true);

        event.preventDefault();
        event.stopPropagation();
    }

    async function onDrop(event: DragEvent<HTMLDivElement>) {

        setDragOver(false);

        event.preventDefault();
        event.stopPropagation();

        await onUploadFiles(event.dataTransfer);
    }

    return (
        <div className="w-full h-full p-4 overflow-y-auto">
            <div 
                id="upload-drop-area"
                className={dragOver ? "highlight" : ""}
                onDragEnter={event => onDragEnter(event)}
                onDragLeave={event => onDragLeave(event)}
                onDragOver={event => onDragOver(event)}
                onDrop={event => onDrop(event)}
                >
                <p className="mb-6">Drop files here to upload them or click the button below to choose files.</p>
                <input
                    type="file"
                    className="hidden"
                    id="upload-file-input" 
                    multiple 
                    accept="image/*"
                    onChange={async event => {
                        if (event.target.files) {
                            await onUploadFiles({ files: event.target.files });
                        }

                        //
                        // Clears the file input.
                        // https://stackoverflow.com/a/42192710/25868
                        //
                        (event.target.value as any) = null;                        
                    }}
                    />
                <label 
                    className="inline-block p-4 cursor-pointer rounded-lg border-2 border-blue-200 hover:border-blue-400 border-solid bg-blue-100" 
                    htmlFor="upload-file-input"
                    >
                    Choose files
                </label>
            </div>

            <div>Uploading: {isUploading}</div>
            <div>Total: {uploads.length}</div>
            <div>Uploaded: {numUploaded}</div>

            <div className="flex flex-wrap">
                {uploads.map((upload, index) => {
                    return (
                        <div key={index} className="relative">
                            <img 
                                className="w-28 h-28 object-cover"
                                src={upload.thumbnailDataUrl}
                                />
                            {(upload.status === "pending" || upload.status === "uploading")
                                && <div 
                                    className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0"
                                    >
                                    <Spinner show={upload.status === "uploading"} />
                                </div>
                            }
                        </div>
                    );
                })}
            </div>
        </div>
    );
}

