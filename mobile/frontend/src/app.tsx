import React, { useEffect, useRef } from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, AuthContextProvider, DbSyncContextProvider, GalleryContextProvider, IAssetUpdateRecord, IAssetUploadRecord, IndexeddbContextProvider, Main, PersistentQueue, UploadContextProvider, useApi, useApp, useIndexeddb, useLocalGallerySink, useLocalGallerySource } from "user-interface";
import { Auth0Provider, useAuth0 } from "@auth0/auth0-react";
import { App as CapacitorApp } from "@capacitor/app";
import { Browser } from "@capacitor/browser";
import { ComputerPage } from "./pages/computer";
import { ScanContextProvider } from "./context/scan-context";
import dayjs from "dayjs";

function GallerySetup() {
    const { setId } = useApp();
    const api = useApi();
    const indexeddb = useIndexeddb();
    const userDatabase = indexeddb.databases.database("user");
    const outgoingAssetUploadQueue = useRef<PersistentQueue<IAssetUploadRecord>>(new PersistentQueue<IAssetUploadRecord>(userDatabase, "outgoing-asset-upload"));
    const outgoingAssetUpdateQueue = useRef<PersistentQueue<IAssetUpdateRecord>>(new PersistentQueue<IAssetUpdateRecord>(userDatabase, "outgoing-asset-update"));
    const localSource = useLocalGallerySource({ setId, indexeddbDatabases: indexeddb.databases, api });
    const localSink = useLocalGallerySink({ setId, outgoingAssetUploadQueue: outgoingAssetUploadQueue.current, outgoingAssetUpdateQueue: outgoingAssetUpdateQueue.current, indexeddbDatabases: indexeddb.databases });

    return (
        <ScanContextProvider>
            <DbSyncContextProvider
                indexeddbDatabases={indexeddb.databases}
                outgoingAssetUpdateQueue={outgoingAssetUpdateQueue.current}
                outgoingAssetUploadQueue={outgoingAssetUploadQueue.current}
                >
                <GalleryContextProvider 
                    source={localSource} // The source of assets to display in the gallery.
                    sink={localSink}     // The sink for outgoing asset uploads and edits.
                    sortFn={asset => dayjs(asset.sortDate).toDate()}
                    groupFn={asset => dayjs(asset.sortDate).format("MMM, YYYY")}
                    >
                    <UploadContextProvider>
                        <Main
                            computerPage={<ComputerPage />} 
                            />
                    </UploadContextProvider>
                </GalleryContextProvider>
            </DbSyncContextProvider>
        </ScanContextProvider>
    );
}

function ApiSetup() {
    return (        
        <ApiContextProvider>
            <IndexeddbContextProvider>
                <GallerySetup />
            </IndexeddbContextProvider>
        </ApiContextProvider>
    );
}

export function App() {

    return (
        <HashRouter>
            <Auth0Provider
                domain={process.env.AUTH0_DOMAIN as string}
                clientId={process.env.AUTH0_CLIENT_ID as string}
                useRefreshTokens={true}
                useRefreshTokensFallback={false}
                authorizationParams={{
                    audience: process.env.AUTH0_AUDIENCE as string,
                    redirect_uri: `${process.env.AUTH0_ORIGIN}/on_login`,
                }}
                >
                <AuthContextProvider
                    openUrl={async (url: string) => {
                        console.log(`>>>> Opening URL: ${url}`);
                        //
                        // Redirect using Capacitor's Browser plugin
                        // https://auth0.com/docs/quickstart/native/ionic-react/01-login
                        //
                        await Browser.open({
                            url,
                            windowName: "_self"
                        });
                    }}
                    >
                    <HandleAuthCallback />
                    <ApiSetup />
                </AuthContextProvider>
            </Auth0Provider>
       </HashRouter>
    );
}

//
// This component handles the Auth0 callback.
//
function HandleAuthCallback() {
    const { handleRedirectCallback } = useAuth0();

    useEffect(() => {
        // Handles the 'appUrlOpen' event and calls `handleRedirectCallback`.
        CapacitorApp.addListener('appUrlOpen', async ({ url }) => {
            console.log(`>>>> Handling appUrlOpen for URL: ${url}`);
            if (url.includes('state') && (url.includes('code') || url.includes('error'))) {
                await handleRedirectCallback(url);
            }

            // No-op on Android.
            await Browser.close();
        });
    }, [handleRedirectCallback]);
    
    return <></>;
}