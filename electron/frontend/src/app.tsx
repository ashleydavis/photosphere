import React, { useRef } from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, AuthContextProvider, DbSyncContextProvider, GalleryContextProvider, IAssetUpdateRecord, IAssetUploadRecord, IndexeddbContextProvider, Main, PersistentQueue, UploadContextProvider, isProduction, useApi, useApp, useIndexeddb, useLocalGallerySink, useLocalGallerySource } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";
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
                    <ScanContextProvider>
                        <Main
                            computerPage={<ComputerPage />} 
                            />
                    </ScanContextProvider>
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
                    <GallerySetup />
                </IndexeddbContextProvider>
            </ApiContextProvider>
        </AuthContextProvider>
    );
}

export function App() {
    if (isProduction) {
        // Setup with authentication.
        return (
            <HashRouter>
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
            </HashRouter>
        );
    }
    else {
        // Setup for dev and testing with no authentication.
        return (
            <HashRouter>
                <ApiSetup />
            </HashRouter>
        );
    }
}
