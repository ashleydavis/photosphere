import React, { useRef } from "react";
import { BrowserRouter } from "react-router-dom";
import { Main, ApiContextProvider, UploadContextProvider, AuthContextProvider, isProduction, GalleryContextProvider, useLocalGallerySource, useLocalGallerySink, useIndexeddbGallerySource, useIndexeddbGallerySink, useCloudGallerySource, useCloudGallerySink, IndexeddbContextProvider, DbSyncContextProvider, useIndexeddb, useApi } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";
import { IIndexeddbDatabase, IPersistentQueue, PersistentQueue, IAssetUploadRecord, IAssetUpdateRecord, CloudDatabases } from "database";

//
// Use the outgoing queue as a React hook.
//
export function useOutgoingUpdateQueue<RecordT>(database: IIndexeddbDatabase, collectionName: string): IPersistentQueue<RecordT> {
    const queue = useRef<PersistentQueue<RecordT>>(new PersistentQueue<RecordT>(database, collectionName));
    return queue.current;
}

function GallerySetup() {

    const api = useApi();
    const cloudDatabases = new CloudDatabases(api);

    const indexeddb = useIndexeddb();
    const indexeddbSource = useIndexeddbGallerySource({ indexeddbDatabases: indexeddb.databases });
    const indexeddbSink = useIndexeddbGallerySink({ indexeddbDatabases: indexeddb.databases });

    const cloudSource = useCloudGallerySource({ api });
    const cloudSink = useCloudGallerySink({ api });

    const userDatabase = indexeddb.databases.database("user");
    const outgoingAssetUploadQueue = useOutgoingUpdateQueue<IAssetUploadRecord>(userDatabase, "outgoing-asset-upload");
    const outgoingAssetUpdateQueue = useOutgoingUpdateQueue<IAssetUpdateRecord>(userDatabase, "outgoing-asset-update");
    const localSource = useLocalGallerySource({ indexeddbSource, indexeddbSink, cloudSource });
    const localSink = useLocalGallerySink({ indexeddbSink, outgoingAssetUploadQueue });

    return (
        <DbSyncContextProvider
            cloudDatabases={cloudDatabases}
            cloudSource={cloudSource}
            cloudSink={cloudSink}
            indexeddbDatabases={indexeddb.databases}
            indexeddbSource={indexeddbSource}
            indexeddbSink={indexeddbSink}
            localSource={localSource}
            outgoingAssetUpdateQueue={outgoingAssetUpdateQueue}
            outgoingAssetUploadQueue={outgoingAssetUploadQueue}
            >
            <GalleryContextProvider 
                source={localSource} // The source of assets to display in the gallery.
                sink={localSink}     // The sink for outgoing asset uploads and edits.
                databases={indexeddb.databases} // The local databases. 
                outgoingAssetUpdateQueue={outgoingAssetUpdateQueue} // The queue for outgoing asset updates.
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

