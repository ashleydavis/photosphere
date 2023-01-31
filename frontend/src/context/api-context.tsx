import React, { createContext, ReactNode, useContext } from "react";
import { IGalleryItem } from "../components/gallery-item";
import axios from "axios";
import { IResolution } from "../lib/image";

const BASE_URL = process.env.BASE_URL as string;
if (!BASE_URL) {
    throw new Error(`Set BASE_URL environment variable to the URL for the Photosphere backend.`);
}

console.log(`Expecting backend at ${BASE_URL}.`);

export interface IApiContext {

    //
    // Makes a full URL to a route in the REST API.
    //
    makeUrl(route: string): string;

    //
    // Retreives the list of assets from the backend.
    //
    getAssets(): Promise<IGalleryItem[]>;

    //
    // Uploads an asset to the backend.
    //
    uploadAsset(file: File, imageResolution: IResolution): Promise<void>;
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
    async function getAssets(): Promise<IGalleryItem[]> {
        const response = await axios.get(`${BASE_URL}/assets`);
        return response.data.assets;
    }

    //
    // Uploads an asset to the backend.
    //
    async function uploadAsset(file: File, imageResolution: IResolution): Promise<void> {
        await axios.post(`${BASE_URL}/asset`, file, {
            headers: {
                "file-name": file.name,
                "content-type": file.type,
                "width": imageResolution.width,
                "height": imageResolution.height,

                //
                // Hash added to satisfy backend requirements.
                // Will compute a proper hash from the file data in the future.
                //
                "hash": "1234", 
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

