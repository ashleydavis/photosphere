import React, { useState, DragEvent, useEffect } from "react";
import { getExifData, getImageResolution, resizeImage } from "../lib/image";
import { useApi } from "../context/api-context";
import { computeHash, loadDataURL } from "../lib/file";
import { convertExifCoordinates, reverseGeocode } from "../lib/reverse-geocode";
import { IUploadDetails, UploadState } from "../lib/upload-details";

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
    // Uploads a list of files.
    //
    async function onUploadFiles(files: FileList) {
        for (const file of files) {
            await uploadFile(file);
        }
    };

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

        const items = event.dataTransfer.items;
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
            // A set of files was dropped.
            //
            const files = event.dataTransfer.files;
            if (files) {
                await onUploadFiles(files);
            }
        }
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
                        await onUploadFiles(event.target.files!);
                        
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
                                    {upload.status === "uploading"
                                        && <div className="" role="status">
                                            <svg aria-hidden="true" className="w-8 h-8 mr-2 text-gray-200 animate-spin dark:text-gray-600 fill-white" viewBox="0 0 100 101" fill="none" xmlns="http://www.w3.org/2000/svg">
                                                <path d="M100 50.5908C100 78.2051 77.6142 100.591 50 100.591C22.3858 100.591 0 78.2051 0 50.5908C0 22.9766 22.3858 0.59082 50 0.59082C77.6142 0.59082 100 22.9766 100 50.5908ZM9.08144 50.5908C9.08144 73.1895 27.4013 91.5094 50 91.5094C72.5987 91.5094 90.9186 73.1895 90.9186 50.5908C90.9186 27.9921 72.5987 9.67226 50 9.67226C27.4013 9.67226 9.08144 27.9921 9.08144 50.5908Z" fill="currentColor"/>
                                                <path d="M93.9676 39.0409C96.393 38.4038 97.8624 35.9116 97.0079 33.5539C95.2932 28.8227 92.871 24.3692 89.8167 20.348C85.8452 15.1192 80.8826 10.7238 75.2124 7.41289C69.5422 4.10194 63.2754 1.94025 56.7698 1.05124C51.7666 0.367541 46.6976 0.446843 41.7345 1.27873C39.2613 1.69328 37.813 4.19778 38.4501 6.62326C39.0873 9.04874 41.5694 10.4717 44.0505 10.1071C47.8511 9.54855 51.7191 9.52689 55.5402 10.0491C60.8642 10.7766 65.9928 12.5457 70.6331 15.2552C75.2735 17.9648 79.3347 21.5619 82.5849 25.841C84.9175 28.9121 86.7997 32.2913 88.1811 35.8758C89.083 38.2158 91.5421 39.6781 93.9676 39.0409Z" fill="currentFill"/>
                                            </svg>
                                        </div>
                                    }
                                </div>
                            }
                        </div>
                    );
                })}
            </div>
        </div>
    );
}

