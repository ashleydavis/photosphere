import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { getExifData, getImageResolution, loadImage, resizeImage } from "../lib/image";
import { computeHash, loadDataURL } from "../lib/file";
import { convertExifCoordinates, isLocationInRange, reverseGeocode } from "../lib/reverse-geocode";
import { IQueuedUpload, IUploadDetails, UploadState } from "../lib/upload-details";

import dayjs from "dayjs";
import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

import JSZip from "jszip";
import mimeTypes from "mime-types";
import { retry } from "../lib/retry";
import { base64StringToBlob } from "blob-util";
import { useGallery } from "./gallery-context";
import { uuid } from "../lib/uuid";

//
// Size of the thumbnail to generate and display during uploaded.
//
const PREVIEW_THUMBNAIL_MIN_SIZE = 60;

//
// Size of the thumbnail to generate and upload to the backend.
//
const THUMBNAIL_MIN_SIZE = 300;

//
// Size of the display asset to generated and uploaded to the backend.
//
const DISPLAY_MIN_SIZE = 1000;

export interface IUploadContext {
    //
    // Uploads a collection of files.
    //
    uploadFiles(dataTransfer: { items?: DataTransferItemList, files?: File[] }): Promise<void>;

    //
    // User has chosen to retry failed uploads.
    //
    retryFailedUploads(): Promise<void>;

    //
    // Counts the number of scans for assets that are currently in progress.
    //
    numScans: number;

    //
    // Set to true when currenlty uploading.
    //
    isUploading: boolean;

    //
    // Number of assets that have been uploaded so far.
    //
    numUploaded: number;

    //
    // Number of assets that were found to be already uploaded.
    //
    numAlreadyUploaded: number;

    //
    // Uploads that have failed.
    //
    failed: IQueuedUpload[];

    //
    // List of uploads in progress.
    //
    uploads: IQueuedUpload[];
}

const UploadContext = createContext<IUploadContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function UploadContextProvider({ children }: IProps) {

    //
    // Interface to the gallery.
    //
    const { addAsset, uploadAsset, checkAsset } = useGallery();

    //
    // List of uploads that failed.
    //
    const [failed, setFailed] = useState<IQueuedUpload[]>([]);

    //
    // List of uploads in progress.
    //
    const [uploads, setUploads] = React.useState<IQueuedUpload[]>([]);

    //
    // Counts the number of scans for assets that are currently in progress.
    //
    const [numScans, setNumScans] = React.useState<number>(0);

    //
    // Set to true when currenlty uploading.
    //
    const [isUploading, setIsUploading] = useState<boolean>(false);

    //
    // Number of assets that have been uploaded so far.
    //
    const [numUploaded, setNumUploaded] = useState<number>(0);

    //
    // Number of assets that were found to be already uploaded.
    //
    const [numAlreadyUploaded, setNumAlreadyUploaded] = useState<number>(0);

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
    function updateUpload(uploadUpdate: Partial<IQueuedUpload>, uploadIndex: number): void {
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
            console.log(`Uploading ${nextUpload.fileName}`);

            //
            // This asset is not yet uploaded.
            //
            setUploadStatus("uploading", uploadIndex);

            if (nextUpload.assetContentType === "application/zip") {

                console.log(`Unpacking zip file ${nextUpload.fileName}`);

                //
                // It's a zip file, so read the files in it and queue them for separate upload.
                //
                // TODO. This can't load zip files bigger than 2GB in the browser. I need to handle errors better for this kind of thing.
                //
                const zip = new JSZip();
                const unpacked = await zip.loadAsync(nextUpload.file);
                for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
                    if (!zipObject.dir) {
                        //
                        // Found a file in the zip file.
                        //
                        const blob = await zipObject.async("blob"); //todo: this forces much data to be stored in memory at the same time.
                        const contentType = mimeTypes.lookup(fileName);
                        if (contentType) {
                            const fullFileName = `${nextUpload.fileName}/${fileName}`;
                            await queueUpload(fullFileName, blob, contentType, zipObject.date, nextUpload.labels.concat(["From zip file", nextUpload.fileName]));
                        }
                    }
                }

                setUploadStatus("uploaded", uploadIndex);
            }
            else {
                await uploadFile(nextUpload, uploadIndex);

                console.log(`Upload successful for ${nextUpload.fileName}`);
            }
        }
        catch (err: any) {

            console.error(`Failed to upload ${nextUpload.fileName}`);
            console.error(err && err.stack || err);

            console.log(`Upload failed for ${nextUpload.fileName}`);

            //
            // Mark the upload as failed.
            // This allows asset upload to be attempted again later.
            //
            setUploadStatus("failed", uploadIndex);

            //
            // Add the failed upload to the list that failed.
            // This means we can show it to the user separately.
            //
            setFailed([ ...failed, nextUpload ]);
        }
        finally {
            //
            // Move onto the next upload.
            //
            setUploadIndex(uploadIndex + 1);

            //
            // Uploading has finished (for now).
            //
            setIsUploading(false);
        }
    }

    //
    // Uploads a file.
    //
    async function uploadFile(nextUpload: IQueuedUpload, uploadIndex: number): Promise<void> {

        updateUpload({ numAttempts: nextUpload.numAttempts + 1 }, uploadIndex);

        // if (nextUpload.numAttempts === 1) {
        //     // Blow up on the first attempt
        //     throw new Error("Smeg");
        // }

        const hash = await computeHash(nextUpload.file);
        const existingAssetId = await checkAsset(hash);
        if (existingAssetId) {
            console.log(`Already uploaded ${nextUpload.fileName} with hash ${hash}, uploaded to ${existingAssetId}`);

            setUploadStatus("already-uploaded", uploadIndex);
            setNumUploaded(numUploaded + 1);
            setNumAlreadyUploaded(numAlreadyUploaded + 1);
        }
        else {
            //
            // Load the image and generate thumbnail, etc. 
            // Don't hold any of this data in memory longer than necessary
            // otherwise we get an out of memory error when trying to
            // upload 1000s of assets.
            //
            const imageData = await loadDataURL(nextUpload.file);
            const image = await loadImage(imageData);
            const imageResolution = await getImageResolution(image);
            const thumbnailDataUrl = resizeImage(image, THUMBNAIL_MIN_SIZE);
            const contentTypeStart = 5;
            const thumbContentTypeEnd = thumbnailDataUrl.indexOf(";", contentTypeStart);
            const thumbContentType = thumbnailDataUrl.slice(contentTypeStart, thumbContentTypeEnd);
            const thumbnailData = thumbnailDataUrl.slice(thumbContentTypeEnd + 1 + "base64,".length);
            const displayDataUrl = resizeImage(image, DISPLAY_MIN_SIZE);
            const displayContentTypeEnd = displayDataUrl.indexOf(";", contentTypeStart);
            const displayContentType = displayDataUrl.slice(contentTypeStart, displayContentTypeEnd);
            const displayData = displayDataUrl.slice(displayContentTypeEnd + 1 + "base64,".length);
            const exif = await getExifData(nextUpload.file);

            const uploadDetails: IUploadDetails = {
                ...nextUpload,
                resolution: imageResolution,
                thumbnail: thumbnailData,
                thumbContentType: thumbContentType,
                display: displayData,
                displayContentType: displayContentType,
                hash: hash,
            };

            if (exif) {
                uploadDetails.properties = {
                    exif: exif,
                };

                if (exif.GPSLatitude && exif.GPSLongitude) {
                    const location = convertExifCoordinates(exif);
                    if (isLocationInRange(location)) {
                        uploadDetails.location = await retry(() => reverseGeocode(location), 3, 5000);
                    }
                    else {
                        console.error(`Ignoring out of range GPS coordinates: ${JSON.stringify(location)}, for asset ${uploadDetails.fileName}.`);
                    }
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

            //
            // Add the month and year as labels.
            //
            const photoDate = uploadDetails.photoDate || uploadDetails.fileDate;
            const month = dayjs(photoDate).format("MMMM");
            const year = dayjs(photoDate).format("YYYY");
            uploadDetails.labels = [month, year].concat(uploadDetails.labels);

            //
            // Remove duplicate labels, in case month/year already added.
            //
            uploadDetails.labels = removeDuplicates(uploadDetails.labels);

            const assetId = uuid();

            //
            // Uploads the full asset.
            //
            await uploadAsset(assetId, "asset", uploadDetails.assetContentType, uploadDetails.file);

            //
            // Uploads the thumbnail separately for simplicity and no restriction on size (e.g. if it were passed as a header).
            //
            const thumnailBlob = base64StringToBlob(uploadDetails.thumbnail, uploadDetails.thumbContentType);
            await uploadAsset(assetId, "thumb", uploadDetails.thumbContentType, thumnailBlob);

            //
            // Uploads the display asset separately for simplicity and no restriction on size.
            //
            const displayBlob = base64StringToBlob(uploadDetails.display, uploadDetails.displayContentType);
            await uploadAsset(assetId, "display", uploadDetails.displayContentType, displayBlob);
            
            //
            // Add asset to the gallery.
            //
            await addAsset({
                _id: assetId,
                width: imageResolution.width,
                height: imageResolution.height,
                origFileName: uploadDetails.fileName,
                hash: uploadDetails.hash,
                location: uploadDetails.location,
                fileDate: uploadDetails.fileDate,
                photoDate: uploadDetails.photoDate,
                sortDate: uploadDetails.photoDate || uploadDetails.fileDate,
                uploadDate: dayjs().toISOString(),
                properties: uploadDetails.properties,
                labels: uploadDetails.labels,
                description: "",
                group: "Uploaded",
            });

            console.log(`Uploaded ${assetId}`);

            //
            // Update upload state.
            //
            updateUpload({ status: "uploaded", assetId }, uploadIndex);
        
            //
            // Increment the number uploaded.
            //
            setNumUploaded(numUploaded + 1);        
        }
    }

    //
    // Queue the upload of a file.
    //
    async function queueUpload(fileName: string, file: Blob, contentType: string, fileDate: Date, labels: string[]) {

        if (contentType !== "image/png" && contentType !== "image/jpeg" && contentType !== "application/zip") {
            // Only accept png, jpg and zip files for upload.
            console.log(`Ignoring file ${fileName} with type ${contentType}`);
            return;
        }

        console.log(`Queueing ${fileName}`);
        
        //
        // Do minimal work and store minimal details when queuing an asset for upload.
        //
        const uploadDetails: IQueuedUpload = {
            file: file, //todo: don't want to store this for zip files!
            fileName: fileName,
            assetContentType: contentType,
            status: "pending",
            fileDate: dayjs(fileDate).toISOString(),
            labels: labels,
            numAttempts: 0,

            //
            // Generate a tiny thumbnail to display while uploading.
            // This doesn't cache the original file anywhere because 
            // that would require much more memory and can actually 
            // result in an out of memory error when we attempt to upload
            // 1000s of assets.
            //
            previewThumbnail: await createThumbnail(contentType, file),
        };

        setUploads(uploads => [ ...uploads, uploadDetails ]);

        console.log(`Queued ${fileName}`);
    }

    //
    // Thumbnail for a zip file.
    //
    const zipThumbnail = (
        <div className="w-28 h-28 flex flex-col items-center justify-center">
            <i className="text-7xl fa-regular fa-file-zipper"></i>
        </div>
    );

    //
    // Creates a thumbnail for the file.
    //
    async function createThumbnail(contentType: string, file: Blob): Promise<JSX.Element | undefined> {
        if (contentType.startsWith("image/")) {
            return (
                <img
                    className="w-28 h-28 object-cover"
                    src={resizeImage(await loadImage(await loadDataURL(file)), PREVIEW_THUMBNAIL_MIN_SIZE)}
                />
            );
        }
        else if (contentType === "application/zip") {
            return zipThumbnail;
        }
        else {
            return undefined;
        }
    }

    //
    // Removes duplicate labels.
    // 
    // https://stackoverflow.com/a/9229821/25868
    //
    function removeDuplicates(labels: string[]): string[] {
        return [ ...new Set<string>(labels) ];
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
    async function traverseFileSystem(item: FileSystemEntry, path: string[]): Promise<void> {
        if (item.isFile) {
            // https://developer.mozilla.org/en-US/docs/Web/API/FileSystemEntry
            const file = await getFile(item as FileSystemFileEntry);
            await queueUpload(file.name, file, file.type, dayjs(file.lastModified).toDate(), path);
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
                await traverseFileSystem(entry, path.concat([ item.name ]));
            }
        }
    }

    //
    // Uploads a collection of files.
    //
    // https://developer.mozilla.org/en-US/docs/Web/API/DataTransferItem
    //
    async function uploadFiles(dataTransfer: { items?: DataTransferItemList, files?: File[] }) {

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
                        await traverseFileSystem(entry, []);
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
                const files = dataTransfer.files;
                if (files) {
                    for (const file of files) {
                        await queueUpload(file.name, file, file.type, dayjs(file.lastModified).toDate(), []);
                    }
                }
            }
        }
        finally {
            setNumScans(numScans - 1);
        }
    }

    //
    // User has chosen to retry failed uploads.
    //
    async function retryFailedUploads(): Promise<void> {
        if (failed.length === 0) {
            // 
            // Nothing failed!
            //
            return;
        }

        setFailed([]);
        setUploads(uploads => uploads.map(upload => {
            if (upload.status === "failed") {
                //
                // Reset the failed upload to pending state to make sure it is retried.
                //
                const newUpload: IQueuedUpload = {
                    ...upload,
                    status: "pending",
                };
                return newUpload;
            }
            else {
                // No change.
                return upload;
            }
        }));
    }

    const value: IUploadContext = {
        uploadFiles,
        retryFailedUploads,
        numScans,
        isUploading,
        numUploaded,
        numAlreadyUploaded,
        failed,
        uploads,
    };

    return (
        <UploadContext.Provider value={value} >
            {children}
        </UploadContext.Provider>
    );
}

//
// Use the upload context in a component.
//
export function useUpload(): IUploadContext {
    const context = useContext(UploadContext);
    if (!context) {
        throw new Error(`Upload context is not set! Add UploadContextProvider to the component tree.`);
    }
    return context;
}

