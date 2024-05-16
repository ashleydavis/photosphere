import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import axios from "axios";
import { useAuth } from "./auth-context";
import { IUser } from "../def/user";
import { IAsset } from "../def/asset";
import { IAssetData } from "../def/asset-data";
import { useClientId } from "../lib/use-client-id";
import { IDatabaseOp, IJournalResult, IOpSelection } from "database";

const BASE_URL = process.env.BASE_URL as string;
if (!BASE_URL) {
    throw new Error(`Set BASE_URL environment variable to the URL for the Photosphere backend.`);
}

console.log(`Expecting backend at ${BASE_URL}.`);

//
// The result of the get assets request.
//
export interface IGetAssetsResult {
    //
    // Assets returned from this request.
    // Set to an empty array if no more assets.
    //
    assets: IAsset[];

    //
    // Continuation token for the next page of assets.
    // Set to undefined when no more pages.
    //
    next?: string;
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
    getAssets(collectionId: string, next?: string): Promise<IGetAssetsResult>;

    //
    // Retreives the latest update id for a collection.
    //
    getLatestUpdateId(collectionId: string): Promise<string | undefined>;

    //
    // Retreives the data for an asset from the backend.
    //
    getAsset(collectionId: string, assetId: string, assetType: string): Promise<Blob>;

    //
    // Gets the assets already uploaded with a particular hash.
    //
    checkAssets(collectionId: string, hash: string): Promise<string[] | undefined>;

    //
    // Uploads an asset to the backend.
    //
    uploadSingleAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void>;

    //
    // Submits database operations to the cloud.
    //
    submitOperations(ops: IDatabaseOp[]): Promise<void>;

    //
    // Gets the journal of operations that have been applied to the database.
    //
    getJournal(collectionId: string, lastUpdateId?: string): Promise<IJournalResult>;
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
    // Retreives the list of assets from the backend.
    //
    async function getAssets(collectionId: string, next?: string): Promise<IGetAssetsResult> {
        let url = `${BASE_URL}/assets?col=${collectionId}`;
        if (next) {
            url += `&next=${next}`;
        }

        await loadToken();
        const token = getToken();
        const { data } = await axios.get(
            url, 
            { 
                headers: {                     
                    col: collectionId,
                    Authorization: `Bearer ${token}`,
                    Accept: "application/json",
                },
            }
        );

        return data;
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
    // Gets the assets already uploaded with a particular hash.
    //
    async function checkAssets(collectionId: string, hash: string): Promise<string[] | undefined> {
        await loadToken();
        const token = getToken();
        const url = `${BASE_URL}/check-asset?hash=${hash}&col=${collectionId}`;
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
        return response.data.assetIds;
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

    const value: IApiContext = {
    	isInitialised,
        getUser,
        getAssets,
        getLatestUpdateId,
        getAsset,
        checkAssets,
        uploadSingleAsset,
        submitOperations,
        getJournal,
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

