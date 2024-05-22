import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import axios from "axios";
import { useAuth } from "./auth-context";
import { useClientId } from "../lib/use-client-id";
import { IAsset, IAssetData, IDatabaseOp, IJournalResult, IOpSelection, IUser, IApi, IGetAssetsResult } from "database";
import { IPage } from "database/build/defs/page";

const BASE_URL = process.env.BASE_URL as string;
if (!BASE_URL) {
    throw new Error(`Set BASE_URL environment variable to the URL for the Photosphere backend.`);
}

console.log(`Expecting backend at ${BASE_URL}.`);

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
                    Accept: "application/json",
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
                Accept: "image/*,video/*",
            },
        });
    
        return response.data;
    }

    //
    // Uploads an asset to the backend.
    //
    async function uploadSingleAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        await loadToken();
        const token = getToken();

        await axios.post(
            `${BASE_URL}/asset`, 
            assetData.data, 
            {
                headers: {
                    "content-type": assetData.contentType,
                    col: collectionId,
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
    async function getJournal(collectionId: string, lastUpdateId?: string): Promise<IJournalResult> {
        
        if (!clientId) {
            throw new Error(`Client id not set.`);
        }

        await loadToken();
        const token = getToken();

        const url = `${BASE_URL}/journal`;
        const response = await axios.post(
            url, 
            {
                collectionId,
                lastUpdateId,
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
    // Sets a new record to the database.
    //
    async function setOne(databaseName: string, collectionName: string, recordId: string, record: any): Promise<void> {
        await loadToken();
        const token = getToken();

        const url = `${BASE_URL}/set-one`;
        const response = await axios.post(
            url, 
            {
                databaseName,
                collectionName,
                recordId,
                record,
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
    async function getOne(databaseName: string, collectionName: string, recordId: string): Promise<any> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/get-one?db=${databaseName}&col=${collectionName}&id=${recordId}`;
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
    // Lists all records in the database.
    //
    async function listAll(databaseName: string, collectionName: string, max: number, next?: string): Promise<IPage<string>> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/list-all?db=${databaseName}&col=${collectionName}&max=${max}&next=${next}`;
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
    async function getAll(databaseName: string, collectionName: string, max: number, next?: string): Promise<IPage<any>> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/get-all?db=${databaseName}&col=${collectionName}&max=${max}&next=${next}`;
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
    // Deletes a database record.
    //
    async function deleteOne(databaseName: string, collectionName: string, recordId: string): Promise<void> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/delete-one`;
        const response = await axios.post(
            url, 
            {
                databaseName,
                collectionName,
                recordId,
            },
            {
                headers: {
                    Authorization: `Bearer ${token}`,
                    Accept: "application/json",
                },
            }
        );
    }

    const value: IApi = {
    	isInitialised,
        getUser,
        getLatestUpdateId,
        getAsset,
        uploadSingleAsset,
        submitOperations,
        getJournal,
        setOne,
        getOne,
        listAll,
        getAll,
        deleteOne,
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

