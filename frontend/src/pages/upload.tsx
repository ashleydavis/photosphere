import React, { useState, DragEvent } from "react";
import { getExifData, getImageResolution, resizeImage } from "../lib/image";
import { IUploadDetails, useApi } from "../context/api-context";
import { computeHash, loadDataURL } from "../lib/file";
import { convertExifCoordinates, reverseGeocode } from "../lib/reverse-geocode";

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
    // Uploads a single asset.
    //
    async function uploadFile(file: File) {
        const hash = await computeHash(file);
        const existingAssetId = await api.checkAsset(hash);
        if (existingAssetId) {
            console.log(`Already uploaded ${file.name} with hash ${hash}, uploaded to ${existingAssetId}`);
            return;
        }

        console.log(`Uploading ${file.name}`);

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
            thumbnail: thumbnailData,
            thumbContentType: thumbContentType,
            hash: hash,
        };

        if (exif) {
            uploadDetails.properties = {
                exif: exif,
            };

            if (exif.GPSLatitude && exif.GPSLongitude) {
                uploadDetails.location = await reverseGeocode(convertExifCoordinates(exif));
            }
        }
        const assetId = await api.uploadAsset(uploadDetails);

        console.log(`Uploaded ${assetId}`);
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
                traverseFileSystem(entry, path + item.name);
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
        <div className="p-4">
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
                    }}
                    />
                <label 
                    className="inline-block p-4 cursor-pointer rounded-lg border-2 border-blue-200 hover:border-blue-400 border-solid bg-blue-100" 
                    htmlFor="upload-file-input"
                    >
                    Choose files
                </label>
            </div>
        </div>
    );
}