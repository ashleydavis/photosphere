import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IUploadDetails } from "../lib/upload-details";
import { IGalleryItem } from "../lib/gallery-item";
import axios from "axios";
import { base64StringToBlob } from 'blob-util';
import dayjs from "dayjs";
import { useAuth } from "./auth-context";

const BASE_URL = process.env.BASE_URL as string;
if (!BASE_URL) {
    throw new Error(`Set BASE_URL environment variable to the URL for the Photosphere backend.`);
}

console.log(`Expecting backend at ${BASE_URL}.`);

export interface IApiContext {

    //
    // Set to true once the api is ready to use.
    //
    isInitialised: boolean;

    //
    // Makes a full URL to a route in the REST API.
    //
    makeUrl(route: string): string;

    //
    // The collection ID the user is working with.
    //
    collectionId: string | undefined;

    //
    // Sets the collection the user is working with.
    //
    setCollection(newCollectionId: string): void;

    //
    // Retreives the list of assets from the backend.
    //
    getAssets(): Promise<IGalleryItem[]>;

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

    const {
        isTokenLoaded,
        loadToken,
        getToken,
    } = useAuth();

    //
    // The collection ID the user is working with.
    //
    const collectionId = useRef<string | undefined>(undefined);

    //
    // Set true once authenticated and when the token is loaded.
    //
    const [isInitialised, setIsInitialised] = useState<boolean>(false);

    useEffect(() => {
        if (isTokenLoaded) {
            loadCollection()
                .then(() => {
                    setIsInitialised(true);
                })
                .catch(err => {
                    console.error(`Failed to load collection:`);
                    console.error(err);                
                });
        }
    }, [isTokenLoaded]);

    //
    // Loads the collection the user is working with.
    //
    async function loadCollection(): Promise<void> {
        await loadToken();
        const token = getToken();

        const url = `${BASE_URL}/collections`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                },
            }
        );

        const { defaultCollection } = response.data;
        collectionId.current = defaultCollection;
        
        console.log(`Working with collection: ${collectionId.current}`);
    }

    //
    // Makes a full URL to a route in the REST API.
    //
    function makeUrl(route: string): string {
        let url = `${BASE_URL}${route}&col=${collectionId}`;
        url += `&tok=${getToken()}`;
        return url;
    }

    //
    // Sets the collection the user is working with.
    //
    function setCollection(newCollectionId: string): void {
        collectionId.current = newCollectionId;
    }

    //
    // Retreives the list of assets from the backend.
    //
    async function getAssets(): Promise<IGalleryItem[]> {
        if (!collectionId.current) {
            throw new Error(`Collection ID is not set!`);
        }

        let url = `${BASE_URL}/assets?col=${collectionId}`;

        await loadToken();
        const token = getToken();
        const { data } = await axios.get(
            url, 
            { 
                headers: {                     
                    col: collectionId.current,
                    Authorization: `Bearer ${token}`,
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
        if (!collectionId.current) {
            throw new Error(`Collection ID is not set!`);
        }

        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/check-asset?hash=${hash}&col=${collectionId}`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    col: collectionId.current,
                    Authorization: `Bearer ${token}`,
                },
            }
        );
        return response.data.assetId;
    }

    //
    // Uploads an asset to the backend.
    //
    async function uploadAsset(uploadDetails: IUploadDetails): Promise<string> {
        if (!collectionId.current) {
            throw new Error(`Collection ID is not set!`);
        }

        await loadToken();
        const token = getToken();

        const { data } = await axios.post(
            `${BASE_URL}/metadata`, 
            {
                col: collectionId,
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
                    Authorization: `Bearer ${token}`,
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
                    col: collectionId.current,
                    id: assetId,
                    Authorization: `Bearer ${token}`,
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
                    col: collectionId.current,
                    id: assetId,
                    Authorization: `Bearer ${token}`,
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
                    col: collectionId.current,
                    id: assetId,
                    Authorization: `Bearer ${token}`,
                },
            }
        );

        return assetId;
    }
    

    //
    // Adds a label to an asset.
    //
    async function addLabel(id: string, labelName: string): Promise<void> {
        await loadToken();
        const token = getToken();
        await axios.post(`${BASE_URL}/asset/add-label`, 
            {
                col: collectionId,
                id: id,
                label: labelName,
            },
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                },
            }
        );
    }

    //
    // Renmoves a label from an asset.
    //
    async function removeLabel(id: string, labelName: string): Promise<void> {
        await loadToken();
        const token = getToken();
        await axios.post(
            `${BASE_URL}/asset/remove-label`, 
            {
                col: collectionId,
                id: id,
                label: labelName,
            },
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                },
            }
        );
    }

    //
    // Sets a description for an asset.
    //
    async function setDescription(id: string, description: string): Promise<void> {
        await loadToken();
        const token = getToken();
        await axios.post(
            `${BASE_URL}/asset/description`, 
            {
                col: collectionId,
                id: id,
                description: description,
            },
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                },
            }
        );
    }   

    const value: IApiContext = {
        isInitialised,
        makeUrl,
        collectionId: collectionId.current,
        setCollection: setCollection,
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

