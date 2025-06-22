import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { getExifData, getImageResolution, IResolution, loadImage, resizeImage } from "../lib/image";
import { computeHash, loadDataURL } from "../lib/file";
import { convertExifCoordinates, isLocationInRange, reverseGeocode } from "utils";
import { IQueuedUpload, UploadState } from "../lib/upload-details";

import dayjs from "dayjs";
import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

import JSZip from "jszip";
import mimeTypes from "mime-types";
import { retry } from "utils";
import { base64StringToBlob } from "blob-util";
import { useGallery } from "./gallery-context";
import { RandomUuidGenerator } from "utils";
import { captureVideoThumbnail, loadVideo, unloadVideo } from "../lib/video";
import { IApiKeysConfig, useApi } from "./api-context";

// @ts-ignore
import ColorThief from 'colorthief/dist/color-thief.mjs';

//
// Size of the thumbnail to generate and display during uploaded.
//
const PREVIEW_THUMBNAIL_MIN_SIZE = 60;

//
// Size of the micro thumbnail to generate and upload to the backend.
//
const MICRO_MIN_SIZE = 40;

//
// Size of the thumbnail to generate and upload to the backend.
//
const THUMBNAIL_MIN_SIZE = 300;

//
// Size of the display asset to generate and upload to the backend.
//
const DISPLAY_MIN_SIZE = 1000;

export interface IUploadContext {
    //
    // Queues the upload of a file.
    //
    queueUpload(fileName: string, loadData: () => Promise<Blob>, contentType: string, fileDate: Date, path: string | undefined, labels: string[]): Promise<void>;

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
    const { addGalleryItem, uploadAsset, checkAssetHash } = useGallery();

    const { getApiKeys } = useApi();

    //
    // The Google API key for reverse geocoding.
    //
    const apiKeys = useRef<IApiKeysConfig | undefined>(undefined);

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

    useEffect(() => {
        //
        // Retreives the Google API key for reverse geocoding.
        //
        getApiKeys()
            .then(_apiKeys => {
                apiKeys.current = _apiKeys;                
            }) 
            .catch(err => {
                console.error(`Failed to get API keys from backend.`);
                console.error(err && err.stack || err);
            });               
    }, []);

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
                const unpacked = await zip.loadAsync(await nextUpload.loadData());
                for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
                    if (!zipObject.dir) {
                        //
                        // Found a file in the zip file.
                        //
                        const contentType = mimeTypes.lookup(fileName);
                        if (contentType) {
                            const fullFileName = `${nextUpload.fileName}/${fileName}`;
                            await queueUpload(fullFileName, () => zipObject.async("blob"), contentType, zipObject.date, nextUpload.filePath, nextUpload.labels.concat(["From zip file", nextUpload.fileName]));
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
    // Specifies the details for an asset.
    //
    interface IAssetDetails { 
        //
        // Size of the asset.
        //
        resolution: IResolution;

        //
        // Micro thumbnail for the asset (base 64).
        //
        micro: string;

        //
        // Content type of the micro thumbnail.
        //
        microContentType: string;

        // 
        // Thumbnail for the asset (base 64).
        //
        thumbnail: string;

        //
        // Content type of the thumbnail.
        //
        thumbContentType: string;

        //
        // Optional display asset (base 64).
        //
        displayData?: string

        //
        // Optional content type of the display asset.
        //
        displayContentType?: string;

        //
        // The color of the asset.
        //
        color: [number, number, number];

        //
        // Properties of the asset.
        //
        properties: any;

        //
        // Location of the asset.
        //
        location?: string;

        //
        // Date the photo was taken.
        //
        photoDate: string;

        //
        // Labels for the asset.
        //
        labels: string[];
    }

    //
    // Loads the details for an asset.
    //
    async function loadAssetDetails(fileData: Blob, uploadDetails: IQueuedUpload): Promise<IAssetDetails> {

        const properties: any = {};
        let location: string | undefined = undefined;
        let photoDate = uploadDetails.fileDate;

        if (uploadDetails.assetContentType === "image/jpeg" || uploadDetails.assetContentType === "image/jpg") {
            const exif = await getExifData(fileData);
            if (exif) {
                properties.metadata = exif;

                if (exif.GPSLatitude && exif.GPSLongitude) {
                    const coordinates = convertExifCoordinates(exif);
                    if (!apiKeys.current?.googleApiKey) {
                        console.warn(`Reverse geocoding is not supported without a Google API key.`);
                    }
                    else if (isLocationInRange(coordinates)) {
                        const reverseGeocodingResult = await retry(() => reverseGeocode(coordinates, apiKeys.current!.googleApiKey!), 3, 5000);
                        if (reverseGeocodingResult) {
                            location = reverseGeocodingResult.location;
                            properties.reverseGeocoding = {
                                type: reverseGeocodingResult.type,
                                fullResult: reverseGeocodingResult.fullResult,
                            };
                        }
                    }
                    else {
                        console.error(`Ignoring out of range GPS coordinates: ${JSON.stringify(coordinates)}, for asset ${uploadDetails.fileName}.`);
                    }
                }

                const dateFields = ["DateTime", "DateTimeOriginal", "DateTimeDigitized", "ModifyDate"];
                for (const dateField of dateFields) {
                    const dateStr = exif[dateField];
                    if (dateStr) {
                        try {
                            photoDate = dayjs(dateStr, "YYYY:MM:DD HH:mm:ss").toISOString();
                        }
                        catch (err) {
                            console.error(`Failed to parse date from ${dateStr}`);
                            console.error(err);
                        }
                    }
                }
            }
        }

        //
        // Add the month and year as labels.
        //
        const month = dayjs(photoDate).format("MMMM");
        const year = dayjs(photoDate).format("YYYY");
        let labels = [month, year].concat(uploadDetails.labels);

        //
        // Remove duplicate labels, in case month/year already added.
        //
        labels = removeDuplicates(labels);

        if (uploadDetails.assetContentType.startsWith("video/")) {
            // A video.
            // NOTE: The video is automatically rotated to match the orientation in exif.
            const video = await loadVideo(fileData);
            try {
                const resolution = { width: video.videoWidth, height: video.videoHeight };
                const { dataUrl: thumbnailDataUrl, contentType: thumbContentType } = captureVideoThumbnail(video, THUMBNAIL_MIN_SIZE);
                const thumbnailImage = await loadImage(thumbnailDataUrl); // NOTE: The resolution is automatically rotated the image to match the orientation in exif.
                const { dataUrl: microDataUrl, contentType: microContentType } = resizeImage(thumbnailImage, MICRO_MIN_SIZE);
                
                const contentTypeStart = 5;
                const microContentTypeEnd = microDataUrl.indexOf(";", contentTypeStart);
                const micro = microDataUrl.slice(microContentTypeEnd + 1 + "base64,".length);
                const thumbContentTypeEnd = thumbnailDataUrl.indexOf(";", contentTypeStart);
                const thumbnail = thumbnailDataUrl.slice(thumbContentTypeEnd + 1 + "base64,".length);
                const color = await (new ColorThief()).getColor(thumbnailImage);

                return { 
                    resolution, 
                    micro,
                    microContentType,
                    thumbnail, 
                    thumbContentType,
                    color,
                    properties,
                    location,
                    photoDate,
                    labels,
                };
            }
            finally {
                unloadVideo(video);
            }
        }
        else {
            // An image.
            const image = await loadImage(await loadDataURL(fileData)); // NOTE: The resolution is automatically rotated the image to match the orientation in exif.
            const resolution = await getImageResolution(image); // NOTE: The resolution is automatically rotated the image to match the orientation in exif.
            const { dataUrl: thumbnailDataUrl, contentType: thumbContentType } = resizeImage(image, THUMBNAIL_MIN_SIZE); // NOTE: Resize image changes orientation according to exif.
            const { dataUrl: microDataUrl, contentType: microContentType } = resizeImage(image, MICRO_MIN_SIZE);
            const contentTypeStart = 5;
            const microContentTypeEnd = microDataUrl.indexOf(";", contentTypeStart);
            const micro = microDataUrl.slice(microContentTypeEnd + 1 + "base64,".length);
            const thumbContentTypeEnd = thumbnailDataUrl.indexOf(";", contentTypeStart);
            const thumbnail = thumbnailDataUrl.slice(thumbContentTypeEnd + 1 + "base64,".length);
            const { dataUrl: displayDataUrl, contentType: displayContentType } = resizeImage(image, DISPLAY_MIN_SIZE);
            const displayContentTypeEnd = displayDataUrl.indexOf(";", contentTypeStart);
            const displayData = displayDataUrl.slice(displayContentTypeEnd + 1 + "base64,".length);    
            const color = await (new ColorThief()).getColor(image);
            return { 
                resolution, 
                micro,
                microContentType,
                thumbnail, 
                thumbContentType, 
                displayData, 
                displayContentType,
                color,
                properties,
                location,
                photoDate,
                labels,
            };
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

        const fileData = await nextUpload.loadData();
        const hash = await computeHash(fileData);
        if (await checkAssetHash(hash)) {
            console.log(`Already uploaded ${nextUpload.fileName} with hash ${hash}`);

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
            const { resolution, micro, thumbnail, thumbContentType, displayData, displayContentType, color,
                location, photoDate, properties, labels } = 
                await loadAssetDetails(fileData, nextUpload);

            const uuidGenerator = new RandomUuidGenerator();
            const assetId = uuidGenerator.generate();

            //
            // Uploads the full asset.
            //
            await uploadAsset(assetId, "asset", fileData);

            //
            // Uploads the thumbnail separately for simplicity and no restriction on size (e.g. if it were passed as a header).
            //
            const thumnailBlob = base64StringToBlob(thumbnail, thumbContentType);
            await uploadAsset(assetId, "thumb", thumnailBlob);

            if (displayData) {
                //
                // Uploads the display asset separately for simplicity and no restriction on size.
                //
                const displayBlob = base64StringToBlob(displayData, displayContentType!);
                await uploadAsset(assetId, "display", displayBlob);
            }
            
            //
            // Add asset to the gallery.
            //
            addGalleryItem({
                _id: assetId,
                width: resolution.width,
                height: resolution.height,
                origFileName: nextUpload.fileName,
                origPath: nextUpload.filePath,
                contentType: nextUpload.assetContentType,
                hash,
                location,
                fileDate: nextUpload.fileDate,
                photoDate,
                uploadDate: dayjs().toISOString(),
                properties,
                labels,
                description: "",
                micro,
                color,
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
    // Queues the upload of a file.
    //
    async function queueUpload(fileName: string, loadData: () => Promise<Blob>, contentType: string, fileDate: Date, filePath: string | undefined, labels: string[]): Promise<void> {

        if (!contentType.startsWith("image/") && !contentType.startsWith("video/") && contentType !== "application/zip") {
            // Only accept images, videos and zip files for upload.
            console.log(`Ignoring file ${fileName} with type ${contentType}`);
            return;
        }

        console.log(`Queueing ${fileName}`);
        
        //
        // Do minimal work and store minimal details when queuing an asset for upload.
        //
        const uploadDetails: IQueuedUpload = {
            loadData,
            fileName,
            filePath,
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
            previewThumbnail: await createThumbnail(contentType, loadData),
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

    const videoThumbnail = (
        <div className="w-28 h-28 flex flex-col items-center justify-center">
            <i className="text-7xl fa-regular fa-file-video"></i>
        </div>
    );

    //
    // Creates a thumbnail for the file.
    //
    async function createThumbnail(contentType: string, blobLoader: () => Promise<Blob>): Promise<JSX.Element | undefined> {
        if (contentType.startsWith("image/")) {
            const { dataUrl } = resizeImage(await loadImage(await loadDataURL(await blobLoader())), PREVIEW_THUMBNAIL_MIN_SIZE)
            return (
                <img
                    className="w-28 h-28 object-cover"
                    src={dataUrl}
                />
            );
        }
        else if (contentType.startsWith("video/")) {
            return videoThumbnail;
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
            const file = await getFile(item as FileSystemFileEntry); //todo: Could delay loading of this, but it might not work.
            await queueUpload(file.name, async () => file, file.type, dayjs(file.lastModified).toDate(), path.join("/"), path);
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
                        await queueUpload(file.name, async () => file, file.type, dayjs(file.lastModified).toDate(), undefined, []);
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
        queueUpload,
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

