import React, { useState, DragEvent } from "react";
import { getExifData, getImageResolution, resizeImage } from "../lib/image";
import { IUploadDetails, useApi } from "../context/api-context";
import { computeHash, loadDataURL } from "../lib/file";
import { reverseGeocode } from "../lib/reverse-geocode";

export function UploadPage() {

    //
    // Interface to the API.
    //
    const api = useApi();

    //
    // Set to true when something is dragged over the upload area.
    //
    const [dragOver, setDragOver] = useState<boolean>(false);

    async function onUploadFiles(files: FileList) {
        for (const file of files) {
            const imageData = await loadDataURL(file);
            const imageResolution = await getImageResolution(imageData);
            const thumbnailDataUrl = await resizeImage(imageData, 100);
            const thumContentTypeStart = 5;
            const thumbContentTypeEnd = thumbnailDataUrl.indexOf(";", thumContentTypeStart);
            const thumbContentType = thumbnailDataUrl.slice(thumContentTypeStart, thumbContentTypeEnd);
            const thumbnailData = thumbnailDataUrl.slice(thumbContentTypeEnd + 1 + "base64,".length);
            const hash = await computeHash(file);
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
                    // https://gis.stackexchange.com/a/273402
                    function convertToDegrees([degrees, minutes, seconds]: any[]) {
                        var deg = degrees.numerator/degrees.denominator;
                        var min = minutes.numerator/minutes.denominator;
                        var sec = seconds.numerator/seconds.denominator;
                        return deg + (min/60) + (sec/3600);
                    }
                    const coordinates = {
                        lat: convertToDegrees(exif.GPSLatitude),
                        lng: convertToDegrees(exif.GPSLongitude),
                    };
                    
                    if (exif.GPSLatitudeRef === "S") {
                        // If the latitude reference is "S", the latitude is negative
                        coordinates.lat = coordinates.lat * -1;
                    }
    
                    if (exif.GPSLongitudeRef === "W") {
                        // If the longitude reference is "W", the longitude is negative (thanks ChatGPT!)
                        coordinates.lng = coordinates.lng * -1;
                    }
    
                    uploadDetails.location = await reverseGeocode(coordinates);
                }
            }
            await api.uploadAsset(uploadDetails);
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

    function onDrop(event: DragEvent<HTMLDivElement>) {

        setDragOver(false);

        const files = event.dataTransfer.files;
        if (files) {
            onUploadFiles(files);
        }

        event.preventDefault();
        event.stopPropagation();
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