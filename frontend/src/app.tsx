import React, { useRef } from "react";
import { BrowserRouter } from "react-router-dom";
import { AppContextProvider, Main, ApiContextProvider, UploadContextProvider, AuthContextProvider, isProduction, GalleryContextProvider, useLocalGallerySource, useLocalGallerySink, IndexeddbContextProvider, DbSyncContextProvider, useIndexeddb, useApi, PersistentQueue, IAssetUploadRecord, IAssetUpdateRecord, useApp } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";
import dayjs from "dayjs";

function GallerySetup() {
    const { setId } = useApp();
    const api = useApi();
    const { database } = useIndexeddb();
    const outgoingAssetUploadQueue = useRef<PersistentQueue<IAssetUploadRecord>>(new PersistentQueue<IAssetUploadRecord>(database, "outgoing-asset-upload"));
    const outgoingAssetUpdateQueue = useRef<PersistentQueue<IAssetUpdateRecord>>(new PersistentQueue<IAssetUpdateRecord>(database, "outgoing-asset-update"));
    const localSource = useLocalGallerySource({ setId, database, api });
    const localSink = useLocalGallerySink({ setId, outgoingAssetUploadQueue: outgoingAssetUploadQueue.current, outgoingAssetUpdateQueue: outgoingAssetUpdateQueue.current, database });

    return (
        <DbSyncContextProvider
            database={database}
            outgoingAssetUpdateQueue={outgoingAssetUpdateQueue.current}
            outgoingAssetUploadQueue={outgoingAssetUploadQueue.current}
            >
            <GalleryContextProvider 
                key={setId}          // Force remount when the set id changes.
                source={localSource} // The source of assets to display in the gallery.
                sink={localSink}     // The sink for outgoing asset uploads and edits.
                sortFn={galleryItem => dayjs(galleryItem.sortDate).toDate()}
                groupFn={galleryItem => dayjs(galleryItem.sortDate).format("MMM, YYYY")}
                >
                <UploadContextProvider>
                    <Main />
                </UploadContextProvider>
            </GalleryContextProvider>
        </DbSyncContextProvider>
    );
}

function ApiSetup() {
    return (        
        <AuthContextProvider>
            <ApiContextProvider>
                <IndexeddbContextProvider>
                    <AppContextProvider>
                        <GallerySetup />
                    </AppContextProvider>
                </IndexeddbContextProvider>
            </ApiContextProvider>
        </AuthContextProvider>
    );
}

export function App() {
    if (isProduction) {
        // Setup with authentication.
        return (
            <BrowserRouter>
                <Auth0Provider
                    domain={process.env.AUTH0_DOMAIN as string}
                    clientId={process.env.AUTH0_CLIENT_ID as string}
                    authorizationParams={{
                        audience: process.env.AUTH0_AUDIENCE as string,
                        redirect_uri: `${process.env.AUTH0_ORIGIN}/on_login`,
                    }}
                    >
                    <ApiSetup />
                </Auth0Provider>
            </BrowserRouter>
        );
    }
    else {
        // Setup for dev and testing with no authentication.
        return (
            <BrowserRouter>
                <ApiSetup />
            </BrowserRouter>
        );
    }
}

