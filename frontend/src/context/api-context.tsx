import React, { createContext, ReactNode, useContext } from "react";
import { IGalleryItem } from "../components/gallery-item";
import axios from "axios";
import { IResolution } from "../lib/image";
import { base64StringToBlob } from 'blob-util';

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

    //
    // Hash of the data.
    //
    hash: string;

    //
    // Optional properties, like exif data.
    //
    properties?: any;

    //
    // Reverse geocoded location of the asset, if known.
    //
    location?: string;
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
        //
        // Uploads the full asset and metadata.
        //
        const { data } = await axios.post(`${BASE_URL}/asset`, asset.file, {
            headers: {
                "content-type": asset.file.type,
                "metadata": JSON.stringify({
                    "fileName": asset.file.name,
                    "contentType": asset.file.type,
                    "width": asset.resolution.width,
                    "height": asset.resolution.height,
                    "hash": asset.hash,
                    "properties": asset.properties,
                    "location": asset.location,
                }),
            },
        });

        const { assetId } = data;

        //
        // Uploads the thumbnail separately for simplicity and no restriction on size (e.g. if it were passed as a header).
        //
        const thumnailBlob = base64StringToBlob(asset.thumbnail, asset.thumbContentType);
        await axios.post(`${BASE_URL}/thumb`, thumnailBlob, {
            headers: {
                "content-type": asset.thumbContentType,
                "id": assetId,
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

