import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import axios from "axios";
import { useAuth } from "./auth-context";
import { useClientId } from "../lib/use-client-id";
import { IAssetData } from "../def/asset-data";
import { IDatabaseOp, IUser } from "defs";
import { IRecord } from "../lib/database/database-collection";

const BASE_URL = process.env.BASE_URL as string;
if (!BASE_URL) {
    throw new Error(`Set BASE_URL environment variable to the URL for the Photosphere backend.`);
}

console.log(`Expecting backend at ${BASE_URL}.`);

//
// The result of get the database journal.
//
export interface IJournalResult {
    //
    // Operations recorded against the collection.
    //
    journalRecords: IDatabaseOp[];

    //
    // The id of the latest update that has been retreived.
    //
    latestTime: string;
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
    // Retreives the latest time for the server.
    //
    getLatestTime(): Promise<string | undefined>;

    //
    // Retreives the data for an asset from the backend.
    //
    getAsset(setId: string, assetId: string, assetType: string): Promise<Blob | undefined>;

    //
    // Makes a URL to load an asset.
    //
    makeAssetUrl(setId: string, assetId: string, assetType: string): Promise<string>;

    //
    // Uploads an asset to the backend.
    //
    uploadSingleAsset(setId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void>;

    //
    // Submits database operations to the cloud.
    //
    submitOperations(ops: IDatabaseOp[]): Promise<void>;

    //
    // Gets the journal of operations that have been applied to the database.
    //
    getJournal(lastUpdateTime?: string): Promise<IJournalResult>;

    //
    // Gets one record by id.
    //
    getOne<RecordT extends IRecord>(collectionName: string, id: string): Promise<RecordT>;

    //
    // Gets a page of records from the database.
    //
    getAll<RecordT extends IRecord>(setId: string, collectionName: string, skip: number, limit: number): Promise<RecordT[]>;
}

const ApiContext = createContext<IApi | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function ApiContextProvider({ children }: IProps) {

    const {
        isTokenLoaded,
        loadToken,
        getToken,
    } = useAuth();

    const { clientId } = useClientId();

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
                    Accept: "application/json",
                },
            }
        );

        return response.data;
    }

    //
    // Retreives the latest server time.
    //
    async function getLatestTime(): Promise<string | undefined> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/latest-time`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                    Accept: "application/json",
                },
            }
        );

        return response.data.latestTime;
    }    

    //
    // Retreives the data for an asset from the backend.
    //
    async function getAsset(setId: string, assetId: string, assetType: string): Promise<Blob | undefined> {
        const url = `${BASE_URL}/asset?id=${assetId}&type=${assetType}&set=${setId}`;
        await loadToken();
        const token = getToken();
        const response = await axios.get(url, {
            responseType: "blob",
            headers: {                  
                Authorization: `Bearer ${token}`,
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
    // Makes a URL to load an asset.
    //
    async function makeAssetUrl(setId: string, assetId: string, assetType: string): Promise<string> {
        await loadToken();
        const token = getToken();
        return `${BASE_URL}/asset?id=${assetId}&type=${assetType}&set=${setId}&t=${token}`;
    }

    //
    // Uploads an asset to the backend.
    //
    async function uploadSingleAsset(setId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        await loadToken();
        const token = getToken();

        await axios.post(
            `${BASE_URL}/asset`, 
            assetData.data, 
            {
                headers: {
                    "content-type": assetData.contentType,
                    set: setId,
                    id: assetId,
                    "asset-type": assetType,
                    Authorization: `Bearer ${token}`,
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

        await loadToken();
        const token = getToken();

        await axios.post(
            `${BASE_URL}/operations`, 
            {
                ops,
                clientId,
            },
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                    Accept: "application/json",
                },
            }
        );    
    }

    //
    // Gets the journal of operations that have been applied to the database.
    //
    async function getJournal(lastUpdateTime?: string): Promise<IJournalResult> {
        
        if (!clientId) {
            throw new Error(`Client id not set.`);
        }

        await loadToken();
        const token = getToken();

        const url = `${BASE_URL}/journal`;
        const response = await axios.post(
            url, 
            {
                lastUpdateTime,
                clientId,
            },
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                    Accept: "application/json",
                },
            },
        );

        return response.data;
    }

    //
    // Gets one record by id.
    //
    async function getOne(collectionName: string, recordId: string): Promise<any> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/get-one?col=${collectionName}&id=${recordId}`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                    Accept: "application/json",
                },
            }
        );
        return response.data;
    }

    //
    // Gets a page of records from the database.
    //
    async function getAll<RecordT extends IRecord>(setId: string, collectionName: string, skip: number, limit: number): Promise<RecordT[]> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/get-all?set=${setId}&col=${collectionName}&skip=${skip}&limit=${limit}`;
        const response = await axios.get(
            url, 
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                    Accept: "application/json",
                },
            }
        );
        return response.data;
    }

    const value: IApi = {
    	isInitialised,
        getUser,
        getLatestTime,
        getAsset,
        makeAssetUrl,
        uploadSingleAsset,
        submitOperations,
        getJournal,
        getOne,
        getAll,
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

