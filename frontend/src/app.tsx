import React, { useEffect } from "react";
import { BrowserRouter } from "react-router-dom";
import { Main, ApiContextProvider, UploadContextProvider, SearchContextProvider, AuthContextProvider, isProduction, GalleryContextProvider, useLocalGallerySource, useLocalGallerySink, useIndexeddbGallerySource, useIndexeddbGallerySink, useCloudGallerySource, useCloudGallerySink, useOutgoingQueueSink, useDatabaseSync, IndexeddbContextProvider } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";


//
// Creates a particular database strategy for the app.
//
function useDatabaseStrategy() {
    const indexeddbSource = useIndexeddbGallerySource();
    const indexeddbSink = useIndexeddbGallerySink();

    const cloudSource = useCloudGallerySource();
    const cloudSink = useCloudGallerySink();

    const outgoingSink = useOutgoingQueueSink();
    const localSource = useLocalGallerySource({ indexeddbSource, cloudSource });
    const localSink = useLocalGallerySink({ indexeddbSink, outgoingSink });

    useDatabaseSync({ cloudSink, indexeddbSink, localSource });

    return { source: localSource, sink: localSink };
}

function GallerySetup() {

    const { source, sink } = useDatabaseStrategy();

    return (
        <SearchContextProvider>
            <GalleryContextProvider 
                source={source} // The source of assets to display in the gallery.
                sink={sink}     // The sink for outgoing asset uploads and edits.
                >
                <UploadContextProvider>
                    <Main />
                </UploadContextProvider>
            </GalleryContextProvider>
        </SearchContextProvider>
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

