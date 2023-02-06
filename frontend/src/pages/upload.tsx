import React, { useState, DragEvent, useEffect } from "react";
import { getExifData, getImageResolution, resizeImage } from "../lib/image";
import { useApi } from "../context/api-context";
import { computeHash, loadDataURL } from "../lib/file";
import { convertExifCoordinates, reverseGeocode } from "../lib/reverse-geocode";
import { IUploadDetails, UploadState } from "../lib/upload-details";
import { Spinner } from "../components/spinner";

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
        };

        if (exif) {
            uploadDetails.properties = {
                exif: exif,
            };

            if (exif.GPSLatitude && exif.GPSLongitude) {
                uploadDetails.location = await reverseGeocode(convertExifCoordinates(exif));
            }
        }

        setUploads(uploads => [ ...uploads, uploadDetails ]);

        console.log(`Queued ${file.name}`);
    }

    //
    // Uploads a collection of files.
    //
    async function onUploadFiles(dataTransfer: { items?: DataTransferItemList, files?: FileList }) {
        const items = dataTransfer.items;
        if (items) {
            //
            // A folder was dropped.
            //
            for (const item of items) {
                const fileSystemEntry = item.webkitGetAsEntry();
                if (fileSystemEntry) {
                    await traverseFileSystem(fileSystemEntry, "");
                }
            }
        }
        else {
            //
            // A set of files was dropped or selected.
            //
            const files = dataTransfer.files;
            if (files) {
                for (const file of files) {
                    await uploadFile(file);
                }
            }
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
    function readDirectory(item: FileSystemDirectoryEntry): Promise<FileSystemEntry[]> {
        return new Promise<FileSystemEntry[]>((resolve, reject) => {
            const reader = (item as FileSystemDirectoryEntry).createReader();
            reader.readEntries(resolve, reject);
        });
    }

    //
    // Traverses the file system for files.
    //
    // https://protonet.com/blog/html5-drag-drop-files-and-folders/
    //
    async function traverseFileSystem(item: FileSystemEntry, path: string): Promise<void> {
        if (item.isFile) {
            const file = await getFile(item as FileSystemFileEntry);
            await uploadFile(file);
        }
        else if (item.isDirectory) {
            const entries = await readDirectory(item as FileSystemDirectoryEntry);
            for (const entry of entries) {
                await traverseFileSystem(entry, path + item.name);
            }
        }
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

            <div className="flex flex-wrap h-28">
                {uploads.map((upload, index) => {
                    return (
                        <div key={index} className="relative">
                            <img 
                                className="h-full w-full object-cover"
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

