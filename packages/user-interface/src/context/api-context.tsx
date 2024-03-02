import React, { createContext, ReactNode, useContext } from "react";
import { LocalStorage } from "../lib/local-storage";
import { IUploadDetails } from "../lib/upload-details";
import { IGalleryItem } from "../lib/gallery-item";
import axios from "axios";
import { base64StringToBlob } from 'blob-util';
import dayjs from "dayjs";

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
    getAssets(search: string | undefined, skip: number, limit: number): Promise<IGalleryItem[]>;

    //
    // Check if an asset is already uploaded using its hash.
    //
    checkAsset(hash: string): Promise<string | undefined>;

    //
    // Uploads an asset to the backend.
    //
    uploadAsset(asset: IUploadDetails): Promise<string>;

    //
    // Adds a label to an asset.
    //
    addLabel(id: string, labelName: string): Promise<void>;

    //
    // Renmoves a label from an asset.
    //
    removeLabel(id: string, labelName: string): Promise<void>;

    //
    // Sets a description for an asset.
    //
    setDescription(id: string, description: string): Promise<void>;

}

const ApiContext = createContext<IApiContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function ApiContextProvider({ children }: IProps) {

    //
    // Interface to local storage.
    //
    const localStorage = new LocalStorage();

    //
    // The user's API key, once that is set.
    //
    let apiKey: string | undefined = undefined;

    //
    // Requests the API key from the the user.
    //
    function  requestApiKey(): Promise<string> {
        return new Promise<string>((resolve, reject) => {
            const apiKey = window.prompt("Please enter your API key (just type anything if running against a development backend).");
            if (apiKey) {
                resolve(apiKey);
            }
            else {
                reject(new Error("User didn't provide an API key."));
            }
        });
    }

    //
    // Gets the users API key.
    //
    async function getApiKey(): Promise<string> {
        if (!apiKey) {
            //
            // Try to load the key from local storaage.
            //
            apiKey = await localStorage.get("key");
            if (!apiKey) {
                //
                // Use the user to enter the key.
                //
                apiKey = await requestApiKey();
                if (apiKey) {
                    //
                    // Save the key in local storage for next time.
                    //
                    await localStorage.set("key", apiKey);
                }
            }
        }
        
        return apiKey;
    }

    //
    // Makes a full URL to a route in the REST API.
    //
    function makeUrl(route: string): string {
        let url = `${BASE_URL}${route}`;
        if (apiKey) {
            url += `&key=${apiKey}`;
        }
        return url;
    }

    //
    // Retreives the list of assets from the backend.
    //
    async function getAssets(search: string | undefined, skip: number, limit: number): Promise<IGalleryItem[]> {
        let url = `${BASE_URL}/assets?skip=${skip}&limit=${limit}`;
        if (search && search.length > 0) {
            url += `&search=${search}`;
        }

        const apiKey = await getApiKey();
        const { data } = await axios.get(
            url, 
            { 
                headers: { 
                    "key": apiKey,
                },
            }
        );
        const { assets } = data;
        
        for (const asset of assets) {
            //TODO: This should be configurable.
            asset.group = dayjs(asset.sortDate).format("MMM, YYYY")
        }

        return assets;
    }

    //
    // Check if an asset is already uploaded using its hash.
    //
    async function checkAsset(hash: string): Promise<string | undefined> {
        const apiKey = await getApiKey();
        const url = `${BASE_URL}/check-asset?hash=${hash}`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    "key": apiKey,
                },
            }
        );
        return response.data.assetId;
    }

    //
    // Uploads an asset to the backend.
    //
    async function uploadAsset(uploadDetails: IUploadDetails): Promise<string> {
        //
        // Uploads the full asset and metadata.
        //
        const apiKey = await getApiKey();

        const { data } = await axios.post(
            `${BASE_URL}/metadata`, 
            {
                fileName: uploadDetails.fileName,
                width: uploadDetails.resolution.width,
                height: uploadDetails.resolution.height,
                hash: uploadDetails.hash,
                properties: uploadDetails.properties,
                location: uploadDetails.location,
                fileDate: uploadDetails.fileDate,
                photoDate: uploadDetails.photoDate,
                labels: uploadDetails.labels,
            },
            {
                headers: {
                    "key": apiKey,
                },
            }
        );

        const { assetId } = data;

        //
        // Uploads the full asset.
        //
        await axios.post(
            `${BASE_URL}/asset`, 
            uploadDetails.file, 
            {
                headers: {
                    "content-type": uploadDetails.assetContentType,
                    "id": assetId,
                    "key": apiKey,
                },
            }
        );

        //
        // Uploads the thumbnail separately for simplicity and no restriction on size (e.g. if it were passed as a header).
        //
        const thumnailBlob = base64StringToBlob(uploadDetails.thumbnail, uploadDetails.thumbContentType);
        await axios.post(
            `${BASE_URL}/thumb`, 
            thumnailBlob, 
            {
                headers: {
                    "content-type": uploadDetails.thumbContentType,
                    "id": assetId,
                    "key": apiKey,
                },
            }
        );

        //
        // Uploads the display asset separately for simplicity and no restriction on size.
        //
        const displayBlob = base64StringToBlob(uploadDetails.display, uploadDetails.displayContentType);
        await axios.post(
            `${BASE_URL}/display`, 
            displayBlob, 
            {
                headers: {
                    "content-type": uploadDetails.displayContentType,
                    "id": assetId,
                    "key": apiKey,
                },
            }
        );

        return assetId;
    }
    

    //
    // Adds a label to an asset.
    //
    async function addLabel(id: string, labelName: string): Promise<void> {
        const apiKey = await getApiKey();
        await axios.post(`${BASE_URL}/asset/add-label`, 
            {
                id: id,
                label: labelName,
            },
            {
                headers: {
                    "key": apiKey,
                },
            }
        );
    }

    //
    // Renmoves a label from an asset.
    //
    async function removeLabel(id: string, labelName: string): Promise<void> {
        const apiKey = await getApiKey();
        await axios.post(
            `${BASE_URL}/asset/remove-label`, 
            {
                id: id,
                label: labelName,
            },
            {
                headers: {
                    "key": apiKey,
                },
            }
        );
    }

    //
    // Sets a description for an asset.
    //
    async function setDescription(id: string, description: string): Promise<void> {
        const apiKey = await getApiKey();
        await axios.post(
            `${BASE_URL}/asset/description`, 
            {
                id: id,
                description: description,
            },
            {
                headers: {
                    "key": apiKey,
                },
            }
        );
    }   

    const value: IApiContext = {
        makeUrl,
        getAssets,
        checkAsset,
        uploadAsset,
        addLabel,
        removeLabel,
        setDescription,
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

