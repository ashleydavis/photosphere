import React, { useState, DragEvent, useEffect } from "react";
import { getExifData, getImageResolution, loadImage, resizeImage } from "../lib/image";
import { useApi } from "../context/api-context";
import { computeHash, loadDataURL } from "../lib/file";
import { convertExifCoordinates, reverseGeocode } from "../lib/reverse-geocode";
import { IQueuedUpload, IUploadDetails, UploadState } from "../lib/upload-details";
import { Spinner } from "../components/spinner";
import { useGallery } from "../context/gallery-context";

import dayjs from "dayjs";
import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

import JSZip from "jszip";
import mimeTypes from "mime-types";

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

export function UploadPage() {

    //
    // Interface to the API.
    //
    const api = useApi();
    
    //
    // The interface to the gallery.
    //
    const { reset } = useGallery();
    
    //
    // Set to true when something is dragged over the upload area.
    //
    const [dragOver, setDragOver] = useState<boolean>(false);

	//
    // List of uploads that failed.
    //
    const [failed, setFailed] = useState<IQueuedUpload[]>([]);

    //
    // List of uploads in progress.
    //
    const [uploads, setUploads] = useState<IQueuedUpload[]>([]);

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

            if (nextUpload.contentType === "application/zip") {

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
            setFailed([...failed, nextUpload]);
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
        const hash = await computeHash(nextUpload.file);
        const existingAssetId = await api.checkAsset(hash);
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
        
            //
            // Add the month and year as labels.
            //
            const photoDate = uploadDetails.photoDate || uploadDetails.fileDate;
            const month = dayjs(photoDate).format("MMMM");
            const year = dayjs(photoDate).format("YYYY");
            uploadDetails.labels = [month, year].concat(uploadDetails.labels || []);
        
            //
            // Remove duplicate labels, in case month/year already added.
            //
            uploadDetails.labels = removeDuplicates(uploadDetails.labels);
        
            const assetId = await api.uploadAsset(uploadDetails);
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
            // Resets the state of gallery. 
            // A cheap way to force the uploaded assets to show up.
            //
            await reset();
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
            contentType: contentType,
            status: "pending",
            fileDate: dayjs(fileDate).toISOString(),
            labels: labels,

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
	            const files = Array.from(dataTransfer.files);
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

    //
    // User has chosen to retry failed uploads.
    //
    function onRetryFailedUploads() {
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

            {uploads.length > 0
                && <>
                    <div className="flex flex-col w-full mt-4 pt-2 border-t border-gray-300 border-solid">
                        <h2 className="flex-grow text-xl">Upload stats</h2>
                        <div className="flex flex-wrap ml-2 mt-1">
                            <div className="flex flex-col flex-grow">
                                <div className="flex flex-row items-center">
                                    Total files queued
                                    <span className="text-2xl ml-2">
                                        {uploads.length}
                                    </span>
                                </div>
                                <div className="flex flex-row items-center">
                                    Files uploaded
                                    <span className="text-2xl ml-2">
                                        {numUploaded}
                                    </span>
                                </div>
                            </div>
                            <div className="flex flex-col flex-grow">
                                <div className="flex flex-row items-center">
                                    Files previously uploaded
                                    <span className="text-2xl ml-2">
                                        {numAlreadyUploaded}
                                    </span>
                                </div>
                                <div className="flex flex-row items-center">
                                    Failed uploads
                                    <span className="text-2xl ml-2">
                                        {failed.length}
                                    </span>
                                </div>
                            </div>
                        </div>
                    </div>

                    {failed.length > 0
                        && <>
                            <div className="flex flex-row w-full mt-4 pt-2 border-t border-gray-300 border-solid items-center">
                                <h2 className="flex-grow text-xl">Failed uploads</h2>
                                <button 
                                    className="p-2 cursor-pointer rounded border border-gray-300 hover:border-gray-500 border-solid bg-white"
                                    onClick={onRetryFailedUploads}
                                    >
                                    Retry failed uploads
                                </button>
                            </div>
                            <div className="flex flex-wrap mt-2">
                                {failed.map((upload, index) => {
                                    return (
                                        <div key={index} className="relative">
                                            {upload.previewThumbnail}

                                        <div 
                                                className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0"
                                                >
                                                <i className="text-7xl fa-solid fa-triangle-exclamation"></i>
                                            </div>
                                        </div>
                                    );
                                })}
                            </div>
                        </>
                    }

                    <div className="flex flex-row w-full mt-4 pt-2 border-t border-gray-300 border-solid">
                        <h2 className="text-xl">Upload queue</h2>
                    </div>
                    <div className="flex flex-wrap mt-2">
                        {uploads.map((upload, index) => {
                            return (
                                <div key={index} className="relative">
                                    {upload.previewThumbnail}
                                    
                                    {(upload.status === "pending" || upload.status === "uploading")
                                        && <div 
                                            className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0"
                                            >
                                            <Spinner show={upload.status === "uploading"} />
                                        </div>
                                    }

                                    {(upload.status === "failed")
                                        && <div 
                                            className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0"
                                            >
                                            <i className="text-7xl fa-solid fa-triangle-exclamation"></i>
                                        </div>
                                    }

                                    {(upload.status === "uploaded")
                                        && <div 
                                            className="flex items-center justify-center absolute inset-0"
                                            >
                                            <i className="text-3xl text-white fa-solid fa-check"></i>
                                        </div>
                                    }

                                    {(upload.status === "already-uploaded")
                                        && <div 
                                            className="flex items-center justify-center absolute inset-0"
                                            >
                                            <i className="text-3xl text-white fa-solid fa-cloud"></i>
                                        </div>
                                    }
                                </div>
                            );
                        })}
                    </div>
                </>
            }
        </div>
    );
}

