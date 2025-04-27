import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import axios from "axios";
import { useClientId } from "../lib/use-client-id";
import { IAssetData } from "../def/asset-data";
import { IDatabaseOp, IUser } from "defs";
import { IRecord } from "../lib/database/database-collection";
import { useAuth } from "./auth-context";

const BASE_URL = import.meta.env.VITE_BASE_URL as string;
if (!BASE_URL) {
    throw new Error(`Set VITE_BASE_URL environment variable to the URL for the Photosphere backend.`);
}

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
// Client-side interface to the Photosphere API.
//
export interface IApi {

    //
    // Set to true once the api is ready to use.
    //
    isInitialised: boolean;

    //
    // Loads the user's details.
    //
    getUser(): Promise<IUser>;

    //
    // Retreives the data for an asset from the backend.
    //
    getAsset(setId: string, assetId: string, assetType: string): Promise<Blob | undefined>;

    //
    // Uploads an asset to the backend.
    //
    uploadSingleAsset(setId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void>;

    //
    // Submits database operations to the cloud.
    //
    submitOperations(ops: IDatabaseOp[]): Promise<void>;

    //
    // Gets one record by id.
    //
    getOne<RecordT extends IRecord>(collectionName: string, id: string): Promise<RecordT>;

    //
    // Gets a page of records from the database.
    //
    getAll<RecordT extends IRecord>(setId: string, collectionName: string, next: string | undefined): Promise<IGetAllResponse<RecordT>>;

    //
    // Check if an asset witha  particular hash is already uploaded.
    //
    checkAssetHash(setId: string, hash: string): Promise<boolean>;
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
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser> {

        const { headers } = await getRequestConfig();


        const url = `${BASE_URL}/user`;
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
    async function getAsset(setId: string, assetId: string, assetType: string): Promise<Blob | undefined> {
        const url = `${BASE_URL}/asset?id=${assetId}&type=${assetType}&set=${setId}`;

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
    async function uploadSingleAsset(setId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {

        const { headers } = await getRequestConfig();

        await axios.post(
            `${BASE_URL}/asset`, 
            assetData.data, 
            {
                headers: {
                    ...headers,
                    "content-type": assetData.contentType,
                    set: setId,
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
    async function getOne(collectionName: string, recordId: string): Promise<any> {
        
        const { headers } = await getRequestConfig();

        const url = `${BASE_URL}/get-one?col=${collectionName}&id=${recordId}`;
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
    async function getAll<RecordT extends IRecord>(setId: string, collectionName: string, next: string | undefined): Promise<IGetAllResponse<RecordT>> {

        const { headers } = await getRequestConfig();

        let url = `${BASE_URL}/get-all?set=${setId}&col=${collectionName}`;
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
    async function checkAssetHash(setId: string, hash: string): Promise<boolean> {
        
        const { headers } = await getRequestConfig();

        const url = `${BASE_URL}/check-hash?set=${setId}&hash=${hash}`;
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
        getUser,
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

