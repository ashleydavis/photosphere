import React, { useEffect } from "react";
import { BrowserRouter } from "react-router-dom";
import { Main, ApiContextProvider, UploadContextProvider, SearchContextProvider, AuthContextProvider, isProduction, GalleryContextProvider, useLocalGallerySource, useLocalGallerySink, useIndexeddbGallerySource, useIndexeddbGallerySink, useCloudGallerySource, useCloudGallerySink, useOutgoingQueueSink, useDatabaseSync } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";

function GallerySetup() {

    const indexeddbSource = useIndexeddbGallerySource();
    const indexeddbSink = useIndexeddbGallerySink();

    const cloudSource = useCloudGallerySource();
    const cloudSink = useCloudGallerySink();

    const outgoingSink = useOutgoingQueueSink();
    const localSource = useLocalGallerySource({ indexeddbSource, cloudSource });
    const localSink = useLocalGallerySink({ indexeddbSink, outgoingSink });

    useDatabaseSync({ cloudSink });

    return (
        <SearchContextProvider>
            <GalleryContextProvider 
                source={localSource}
                sink={localSink}
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
                <GallerySetup />
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

