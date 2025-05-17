import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import axios from "axios";
import { useClientId } from "../lib/use-client-id";
import { IDatabaseOp, IMediaFileDatabases } from "defs";
import { IRecord } from "../lib/database/database-collection";
import { useAuth } from "./auth-context";

export const BASE_URL = import.meta.env.VITE_BASE_URL as string;

console.log(`Expecting backend at ${BASE_URL}.`);

//
// Response from the backend when getting a page of records.
//
export interface IGetAllResponse<RecordT> {
    //
    // The records returned from the database.
    //
    records: RecordT[];

    //
    // The next page of records, if available.
    //
    next: string | undefined;
}

//
// Configuration for API keys.
//
export interface IApiKeysConfig { 
    //
    // Google API key for reverse geocoding, if provided.
    //
    googleApiKey?: string; 
}

//
// Client-side interface to the Photosphere API.
//
export interface IApi {

    //
    // Set to true once the api is ready to use.
    //
    isInitialised: boolean;

    //
    // Gets the Google API key from the backend.
    //
    getApiKeys(): Promise<IApiKeysConfig>;

    //
    // Gets the available media libraries.
    //
    getDatabases(): Promise<IMediaFileDatabases>;

    //
    // Retreives the data for an asset from the backend.
    //
    getAsset(databaseId: string, assetId: string, assetType: string): Promise<Blob | undefined>;

    //
    // Uploads an asset to the backend.
    //
    uploadSingleAsset(databaseId: string, assetId: string, assetType: string, assetData: Blob): Promise<void>;

    //
    // Submits database operations to the cloud.
    //
    submitOperations(ops: IDatabaseOp[]): Promise<void>;

    //
    // Gets one record by id.
    //
    getOne<RecordT extends IRecord>(databaseId: string, collectionName: string, id: string): Promise<RecordT>;

    //
    // Gets a page of records from the database.
    //
    getAll<RecordT extends IRecord>(databaseId: string, collectionName: string, next: string | undefined): Promise<IGetAllResponse<RecordT>>;

    //
    // Check if an asset witha  particular hash is already uploaded.
    //
    checkAssetHash(databaseId: string, hash: string): Promise<boolean>;
}

const ApiContext = createContext<IApi | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function ApiContextProvider({ children }: IProps) {

    const { 
        isAuthenticated,
        getRequestConfig,
    } = useAuth();

    const { clientId } = useClientId();

    //
    // Set true once authenticated and when the token is loaded.
    //
    const [isInitialised, setIsInitialised] = useState<boolean>(false);

    useEffect(() => {
        if (isAuthenticated && !isInitialised) {
            setIsInitialised(true);
        }
    }, [isAuthenticated]);

    //
    // Gets the Google API key from the backend.
    //
    async function getApiKeys(): Promise<IApiKeysConfig> {
        const { headers } = await getRequestConfig();
        const url = `${BASE_URL}/auth/api-keys`;
        const response = await axios.get(
            url,
            {
                headers: {
                    ...headers,
                    Accept: "application/json",
                },
            }
        );
        return response.data;
    }

    //
    // Loads the available media libraries.
    //
    async function getDatabases(): Promise<IMediaFileDatabases> {

        const { headers } = await getRequestConfig();

        const url = `${BASE_URL}/dbs`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    ...headers,
                    Accept: "application/json",
                },
            }
        );

        return response.data;
    }

    //
    // Retreives the data for an asset from the backend.
    //
    async function getAsset(databaseId: string, assetId: string, assetType: string): Promise<Blob | undefined> {
        const url = `${BASE_URL}/asset?id=${assetId}&type=${assetType}&db=${databaseId}`;

        const { headers } = await getRequestConfig();

        const response = await axios.get(url, {
            responseType: "blob",
            headers: {           
                ...headers,       
                Accept: "image/*,video/*",
            },
            validateStatus: status => (status >= 200 && status < 300) || status === 404,
        });

        if (response.status === 404) {
            return undefined;
        }
    
        return response.data;
    }

    //
    // Uploads an asset to the backend.
    //
    async function uploadSingleAsset(databaseId: string, assetId: string, assetType: string, assetData: Blob): Promise<void> {

        const { headers } = await getRequestConfig();

        await axios.post(
            `${BASE_URL}/asset`, 
            assetData, 
            {
                headers: {
                    ...headers,
                    "content-type": assetData.type,
                    db: databaseId,
                    id: assetId,
                    "asset-type": assetType,
                    Accept: "application/json",
                },
            }
        );
    }

    //
    // Submits database operations to the cloud.
    //
    async function submitOperations(ops: IDatabaseOp[]): Promise<void> {

        if (!clientId) {
            throw new Error(`Client id not set.`);
        }

        const { headers } = await getRequestConfig();
        
        await axios.post(
            `${BASE_URL}/operations`, 
            {
                ops,
                clientId,
            },
            {
                headers: {
                    ...headers,
                    Accept: "application/json",
                },
            }
        );    
    }

    //
    // Gets one record by id.
    //
    async function getOne(databaseId: string, collectionName: string, recordId: string): Promise<any> {
        
        const { headers } = await getRequestConfig();

        const url = `${BASE_URL}/get-one?db=${databaseId}&col=${collectionName}&id=${recordId}`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    ...headers,
                    Accept: "application/json",
                },
            }
        );
        return response.data;
    }

    //
    // Gets a page of records from the database.
    //
    async function getAll<RecordT extends IRecord>(databaseId: string, collectionName: string, next: string | undefined): Promise<IGetAllResponse<RecordT>> {

        const { headers } = await getRequestConfig();

        let url = `${BASE_URL}/get-all?db=${databaseId}&col=${collectionName}`;
        if (next) {
            url += `&next=${next}`;
        }
        const response = await axios.get(
            url, 
            {
                headers: {
                    ...headers,
                    Accept: "application/json",
                },
            }
        );
        return response.data;
    }

    //
    // Check if an asset with a particular hash is already uploaded.
    //
    async function checkAssetHash(databaseId: string, hash: string): Promise<boolean> {
        
        const { headers } = await getRequestConfig();

        const url = `${BASE_URL}/check-hash?db=${databaseId}&hash=${hash}`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    ...headers,
                    Accept: "application/json",
                },
            }
        );
        
        const assetIds = response.data.assetIds;
        return assetIds.length > 0;        
    }

    const value: IApi = {
    	isInitialised,
        getApiKeys,
        getDatabases,
        getAsset,
        uploadSingleAsset,
        submitOperations,
        getOne,
        getAll,
        checkAssetHash,
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
export function useApi(): IApi {
    const context = useContext(ApiContext);
    if (!context) {
        throw new Error(`API context is not set! Add ApiContextProvider to the component tree.`);
    }
    return context;
}

