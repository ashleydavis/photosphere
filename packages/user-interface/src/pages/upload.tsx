import React, { useState, DragEvent } from "react";
import { useUpload } from "../context/upload-context";
import { Spinner } from "../components/spinner";
import { useDatabaseSync } from "../context/database-sync";

export function UploadPage() {

    //
    // Interface to the upload context.
    //
    const { 
        uploadFiles, 
        retryFailedUploads, 
        failed, 
        uploads, 
        numUploaded, 
        numAlreadyUploaded, 
    } = useUpload();

    const { isInitialized } = useDatabaseSync();

    //
    // Set to true when something is dragged over the upload area.
    //
    const [dragOver, setDragOver] = useState<boolean>(false); 

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

        await uploadFiles({ items: event.dataTransfer.items });
    }

    if (!isInitialized) {
        return (
            <div className="w-full h-full p-4 flex items-center justify-center">
                <Spinner show={true} />
            </div>
        );
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
                            await uploadFiles({ files: Array.from(event.target.files) });
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

            {(uploads.length > 0 || failed.length > 0)
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
                                    onClick={retryFailedUploads}
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

                    {uploads.length > 0
                        && <>
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
                </>
            }
        </div>
    );
}
