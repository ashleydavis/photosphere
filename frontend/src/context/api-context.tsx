import React, { createContext, ReactNode, useContext } from "react";
import { IGalleryItem } from "../components/gallery-item";
import axios from "axios";
import { IResolution } from "../lib/image";

const BASE_URL = process.env.BASE_URL as string;
if (!BASE_URL) {
    throw new Error(`Set BASE_URL environment variable to the URL for the Photosphere backend.`);
}

console.log(`Expecting backend at ${BASE_URL}.`);

//
// Details of an asset to be uploaded.
//
export interface IUploadDetails {
    //
    // The original file to upload.
    //
    file: File;
    
    //
    // The resolution of the asset.
    //
    resolution: IResolution;
    
    //
    // Base64 encoded thumbnail for the asset.
    //
    thumbnail: string;
    
    // 
    // The content type of the thumbnail.
    //
    thumbContentType: string;
}

export interface IApiContext {

    //
    // Makes a full URL to a route in the REST API.
    //
    makeUrl(route: string): string;

    //
    // Retreives the list of assets from the backend.
    //
    getAssets(skip: number, limit: number): Promise<IGalleryItem[]>;

    //
    // Uploads an asset to the backend.
    //
    uploadAsset(asset: IUploadDetails): Promise<void>;
}

const ApiContext = createContext<IApiContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function ApiContextProvider({ children }: IProps) {

    //
    // Makes a full URL to a route in the REST API.
    //
    function makeUrl(route: string): string {
        return `${BASE_URL}${route}`;
    }

    //
    // Retreives the list of assets from the backend.
    //
    async function getAssets(skip: number, limit: number): Promise<IGalleryItem[]> {
        const response = await axios.get(`${BASE_URL}/assets?skip=${skip}&limit=${limit}`);
        return response.data.assets;
    }

    //
    // Uploads an asset to the backend.
    //
    async function uploadAsset(asset: IUploadDetails): Promise<void> {
        await axios.post(`${BASE_URL}/asset`, asset.file, {
            headers: {
                "content-type": asset.file.type,
                "metadata": JSON.stringify({
                    "fileName": asset.file.name,
                    "contentType": asset.file.type,
                    "thumbContentType": asset.thumbContentType,
                    "width": asset.resolution.width,
                    "height": asset.resolution.height,
                    //
                    // Hash added to satisfy backend requirements.
                    // Will compute a proper hash from the file data in the future.
                    //
                    "hash": "1234", 
                }),
                "thumbnail": asset.thumbnail,
            },
        });
    }
    
    const value: IApiContext = {
        makeUrl,
        getAssets,
        uploadAsset,
    };
    
    return (
        <ApiContext.Provider value={value} >
            {children}
        </ApiContext.Provider>
    );
}

//
// Use the API context in a component.
//
export function useApi(): IApiContext {
    const context = useContext(ApiContext);
    if (!context) {
        throw new Error(`API context is not set! Add ApiContextProvider to the component tree.`);
    }
    return context;
}

