import React, { useRef } from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, AuthContextProvider, DbSyncContextProvider, GalleryContextProvider, IndexeddbContextProvider, Main, UploadContextProvider, isProduction, useApi, useCloudGallerySink, useCloudGallerySource, useIndexeddb, useIndexeddbGallerySink, useIndexeddbGallerySource, useLocalGallerySink, useLocalGallerySource } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";
import { CloudDatabases, IAssetUpdateRecord, IAssetUploadRecord, PersistentQueue } from "database";
import { ComputerPage } from "./pages/computer";

function GallerySetup() {

    const api = useApi();
    const cloudDatabases = new CloudDatabases(api);

    const indexeddb = useIndexeddb();
    const indexeddbSource = useIndexeddbGallerySource({ indexeddbDatabases: indexeddb.databases });
    const indexeddbSink = useIndexeddbGallerySink({ indexeddbDatabases: indexeddb.databases });

    const cloudSource = useCloudGallerySource({ api });
    const cloudSink = useCloudGallerySink({ api });

    const userDatabase = indexeddb.databases.database("user");
    const outgoingAssetUploadQueue = useRef<PersistentQueue<IAssetUploadRecord>>(new PersistentQueue<IAssetUploadRecord>(userDatabase, "outgoing-asset-upload"));
    const outgoingAssetUpdateQueue = useRef<PersistentQueue<IAssetUpdateRecord>>(new PersistentQueue<IAssetUpdateRecord>(userDatabase, "outgoing-asset-update"));
    const localSource = useLocalGallerySource({ indexeddbSource, indexeddbSink, cloudSource });
    const localSink = useLocalGallerySink({ indexeddbSink, outgoingAssetUploadQueue: outgoingAssetUploadQueue.current, outgoingAssetUpdateQueue: outgoingAssetUpdateQueue.current });

    return (
        <DbSyncContextProvider
            cloudDatabases={cloudDatabases}
            cloudSource={cloudSource}
            cloudSink={cloudSink}
            indexeddbDatabases={indexeddb.databases}
            indexeddbSource={indexeddbSource}
            indexeddbSink={indexeddbSink}
            localSource={localSource}
            outgoingAssetUpdateQueue={outgoingAssetUpdateQueue.current}
            outgoingAssetUploadQueue={outgoingAssetUploadQueue.current}
            >
            <GalleryContextProvider 
                source={localSource} // The source of assets to display in the gallery.
                sink={localSink}     // The sink for outgoing asset uploads and edits.
                >
                <UploadContextProvider>
                    <Main
                        computerPage={<ComputerPage />} 
                        />
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
