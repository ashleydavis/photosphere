import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import axios from "axios";
import dayjs from "dayjs";
import { useAuth } from "./auth-context";

const BASE_URL = process.env.BASE_URL as string;
if (!BASE_URL) {
    throw new Error(`Set BASE_URL environment variable to the URL for the Photosphere backend.`);
}

console.log(`Expecting backend at ${BASE_URL}.`);

export interface IAssetMetadata {
    //
    // The name of the file.
    //
    fileName: string;

    //
    // The width of the image or video.
    //
    width: number;

    //
    // The height of the image or video.
    //
    height: number;

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

    //
    // The data the file was created.
    //
    fileDate: string;

    //
    // The data the photo was taken if known.
    //
    photoDate?: string;

    //
    // Labels to add to the uploaded asset, if any.
    //
    labels: string[];
}

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
    // Retreives the data for an asset from the backend.
    //
    getAsset(assetId: string, type: string): Promise<Blob>;

    //
    // Check if an asset is already uploaded using its hash.
    //
    checkAsset(hash: string): Promise<string | undefined>;

    //
    // Uploads an asset to the backend.
    //
    uploadSingleAsset(assetId: string, type: string, contentType: string, data: Blob): Promise<void>;

    //
    // Uploads an asset's metadata to the backend.
    //
    uploadAssetMetadata(assetMetadata: IAssetMetadata): Promise<string>;

    //
    // Updates an asset's metadata.
    //
    updateAssetMetadata(id: string, assetMetadata: Partial<IAssetMetadata>): Promise<void>;
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

        const url = `${BASE_URL}/user`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                },
            }
        );

        collectionId.current = response.data.collections.default;
        
        console.log(`Working with collection: ${collectionId.current}`);
    }

    //
    // Makes a full URL to a route in the REST API.
    //
    function makeUrl(route: string): string {
        let url = `${BASE_URL}${route}&col=${collectionId.current}`;
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

        let url = `${BASE_URL}/assets?col=${collectionId.current}`;

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
    // Retreives the data for an asset from the backend.
    //
    async function getAsset(assetId: string, type: string): Promise<Blob> {
        const assetUrl = makeUrl(`/${type}?id=${assetId}`);
        const response = await axios.get(assetUrl, {
            responseType: 'blob'
        });
    
        return response.data;
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
        const url = `${BASE_URL}/check-asset?hash=${hash}&col=${collectionId.current}`;
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
    async function uploadSingleAsset(assetId: string, type: string, contentType: string, data: Blob): Promise<void> {
        if (!collectionId.current) {
            throw new Error(`Collection ID is not set!`);
        }

        await loadToken();
        const token = getToken();

        await axios.post(
            `${BASE_URL}/${type}`, 
            data, 
            {
                headers: {
                    "content-type": contentType,
                    col: collectionId.current,
                    id: assetId,
                    Authorization: `Bearer ${token}`,
                },
            }
        );
    }

    //
    // Uploads an asset's metadata to the backend.
    //
    async function uploadAssetMetadata(assetMetadata: IAssetMetadata): Promise<string> {
        if (!collectionId.current) {
            throw new Error(`Collection ID is not set!`);
        }

        await loadToken();
        const token = getToken();
        
        const { data } = await axios.post(
            `${BASE_URL}/metadata`, 
            {
                col: collectionId.current,
                fileName: assetMetadata.fileName,
                width: assetMetadata.width,
                height: assetMetadata.height,
                hash: assetMetadata.hash,
                properties: assetMetadata.properties,
                location: assetMetadata.location,
                fileDate: assetMetadata.fileDate,
                photoDate: assetMetadata.photoDate,
                labels: assetMetadata.labels,
            },
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                },
            }
        );

        const { assetId } = data;
        return assetId;
    }

    //
    // Updates an asset's metadata.
    //
    async function updateAssetMetadata(id: string, assetMetadata: Partial<IAssetMetadata>): Promise<void> {
        await loadToken();
        const token = getToken();
        await axios.patch(`${BASE_URL}/metadata`, 
            {
                col: collectionId.current,
                id: id,
                update: assetMetadata,
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
        getAsset,
        checkAsset,
        uploadSingleAsset,
        uploadAssetMetadata,
        updateAssetMetadata,
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

