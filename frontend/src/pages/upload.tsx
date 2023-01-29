import React, { useState, DragEvent } from "react";
import { loadFile, getImageResolution } from "../lib/image";
import { useApi } from "../context/api-context";

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
            const imageData = await loadFile(file);
            const imageResolution = await getImageResolution(imageData);
            await api.uploadAsset(file, imageResolution);
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