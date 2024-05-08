import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import axios from "axios";
import dayjs from "dayjs";
import { useAuth } from "./auth-context";
import { IAssetOps, ICollectionOps, IDbOps } from "../def/ops";
import { IUser } from "../def/user";
import { IAsset } from "../def/asset";

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

//
// Records updates to assets in the collection.
//
export interface IJournalRecord {
    //
    // The date the server received the operation.
    //
    serverTime: string;
    
    //
    // Operations to apply to assets in the collection.
    //
    ops: IAssetOps[];
}

export interface ICollectionOpsResult {
    //
    // Operations against the collection.
    //
    collectionOps: ICollectionOps;

    //
    // The id of the latest asset that has been retreived.
    //
    latestUpdateId?: string;

    //
    // Continuation token for the next page of operations.
    //
    next?: string;
}

//
// Collection of the last update ids for each collection.
//
export interface ICollectionUpdateIds {
    //
    // The latest update id for each collection.
    //
    [collectionId: string]: string;
}

export interface IDpOpsResult {
    //
    // Operations to apply to the database.
    //
    collectionOps: ICollectionOpsResult[];
}

export interface IApiContext {

    //
    // Set to true once the api is ready to use.
    //
    isInitialised: boolean;

    //
    // Loads the user's details.
    //
    getUser(): Promise<IUser>;

    //
    // Retreives the list of assets from the backend.
    //
    getAssets(collectionId: string): Promise<IAsset[]>;

    //
    // Retreives the latest update id for a collection.
    //
    getLatestUpdateId(collectionId: string): Promise<string | undefined>;

    //
    // Retreives the data for an asset from the backend.
    //
    getAsset(collectionId: string, assetId: string, assetType: string): Promise<Blob>;

    //
    // Check if an asset is already uploaded using its hash.
    //
    checkAsset(collectionId: string, hash: string): Promise<string | undefined>;

    //
    // Uploads an asset to the backend.
    //
    uploadSingleAsset(collectionId: string, assetId: string, assetType: string, contentType: string, data: Blob): Promise<void>;

    //
    // TODO: Deprecated in favor of database options.
    //
    // Uploads an asset's metadata to the backend.
    //
    uploadAssetMetadata(collectionId: string, assetId: string, assetMetadata: IAssetMetadata): Promise<void>;

    //
    // TODO: Deprecated in favor of database options.
    //
    // Updates an asset's metadata.
    //
    updateAssetMetadata(collectionId: string, id: string, assetMetadata: Partial<IAssetMetadata>): Promise<void>;

    //
    // Submits database operations to the cloud.
    //
    submitOperations(dbOps: IDbOps): Promise<void>;

    //
    // Retreives latest database operations from the cloud.
    //
    retrieveOperations(lastUpdateIds: ICollectionUpdateIds): Promise<IDpOpsResult>;
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
    // Set true once authenticated and when the token is loaded.
    //
    const [isInitialised, setIsInitialised] = useState<boolean>(false);

    useEffect(() => {
        if (isTokenLoaded) {
            setIsInitialised(true);
        }
    }, [isTokenLoaded]);

    //
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser> {
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

        return response.data;
    }

    //
    // Retreives the list of assets from the backend.
    //
    async function getAssets(collectionId: string): Promise<IAsset[]> {
        let url = `${BASE_URL}/assets?col=${collectionId}`;
        await loadToken();
        const token = getToken();
        const { data } = await axios.get(
            url, 
            { 
                headers: {                     
                    col: collectionId,
                    Authorization: `Bearer ${token}`,
                },
            }
        );

        return data.assets; //todo: Need to care about the "next" field here to get the next page.
    }

    //
    // Retreives the latest update id for a collection.
    //
    async function getLatestUpdateId(collectionId: string): Promise<string | undefined> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/latest-update-id`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    col: collectionId,
                    Authorization: `Bearer ${token}`,
                },
            }
        );

        return response.data.latestUpdateId;
    }    

    //
    // Retreives the data for an asset from the backend.
    //
    async function getAsset(collectionId: string, assetId: string, assetType: string): Promise<Blob> {
        const url = `${BASE_URL}/asset?id=${assetId}&type=${assetType}&col=${collectionId}`; //todo: Some of these parameters might be better as headers.
        await loadToken();
        const token = getToken();
        const response = await axios.get(url, {
            responseType: "blob",
            headers: {                  
                Authorization: `Bearer ${token}`,
            },
        });
    
        return response.data;
    }

    //
    // Check if an asset is already uploaded using its hash.
    //
    async function checkAsset(collectionId: string, hash: string): Promise<string | undefined> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/check-asset?hash=${hash}&col=${collectionId}`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    col: collectionId,
                    Authorization: `Bearer ${token}`,
                },
            }
        );
        return response.data.assetId;
    }

    //
    // Uploads an asset to the backend.
    //
    async function uploadSingleAsset(collectionId: string, assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        await loadToken();
        const token = getToken();

        await axios.post(
            `${BASE_URL}/asset`, 
            data, 
            {
                headers: {
                    "content-type": contentType,
                    col: collectionId,
                    id: assetId,
                    "asset-type": assetType,
                    Authorization: `Bearer ${token}`,
                },
            }
        );
    }

    //
    // TODO: Deprecated in favor of database options.
    //
    // Uploads an asset's metadata to the backend.
    //
    async function uploadAssetMetadata(collectionId: string, assetId: string, assetMetadata: IAssetMetadata): Promise<void> {
        await loadToken();
        const token = getToken();
        
        await axios.post(
            `${BASE_URL}/metadata`, 
            {
                col: collectionId,
                id: assetId,
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
    }

    //
    // TODO: Deprecated in favor of database options.
    //
    // Updates an asset's metadata.
    //
    async function updateAssetMetadata(collectionId: string, id: string, assetMetadata: Partial<IAssetMetadata>): Promise<void> {
        await loadToken();
        const token = getToken();
        await axios.patch(`${BASE_URL}/metadata`, 
            {
                col: collectionId,
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

    //
    // Submits database operations to the cloud.
    //
    async function submitOperations(dbOps: IDbOps): Promise<void> {
        await loadToken();
        const token = getToken();

        await axios.post(
            `${BASE_URL}/operations`, 
            {
                dbOps,
            },
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                },
            }
        );    
    }

    //
    // Retreives latest database operations from the cloud.
    //
    async function retrieveOperations(lastUpdateIds: ICollectionUpdateIds): Promise<IDpOpsResult> {
        await loadToken();
        const token = getToken();

        const url = `${BASE_URL}/operations`;
        const response = await axios.put(
            url, 
            { lastUpdateIds },
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                },
            },
        );

        return response.data; //todo: Need to care about the "next" field here to get the next page.
    }

    const value: IApiContext = {
    	isInitialised,
        getUser,
        getAssets,
        getLatestUpdateId,
        getAsset,
        checkAsset,
        uploadSingleAsset,
        uploadAssetMetadata,
        updateAssetMetadata,
        submitOperations,
        retrieveOperations,
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

