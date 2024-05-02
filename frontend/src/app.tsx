import React from "react";
import { BrowserRouter } from "react-router-dom";
import { Main, ApiContextProvider, UploadContextProvider, SearchContextProvider, AuthContextProvider, isProduction, GalleryContextProvider, useLocalGallerySource, useLocalGallerySink } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";
import { useCloudGallerySource } from "user-interface/build/context/source/cloud-gallery-source";
import { useCloudGallerySink } from "user-interface/build/context/source/cloud-gallery-sink";

function GallerySetup() {

    const cloudSource = useCloudGallerySource();
    const cloudSink = useCloudGallerySink();

    const localSource = useLocalGallerySource({ cloudSource });
    const localSink = useLocalGallerySink({ cloudSink });

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
