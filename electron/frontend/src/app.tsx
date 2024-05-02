import React from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, AuthContextProvider, GalleryContextProvider, Main, SearchContextProvider, UploadContextProvider, useCloudGallerySink, useCloudGallerySource } from "user-interface";
import { ComputerPage } from "./pages/computer";
import { ScanContextProvider } from "./context/scan-context";
import { Auth0Provider } from "@auth0/auth0-react";

function GallerySetup() {

    const source = useCloudGallerySource();
    const sink = useCloudGallerySink();

    return (
        <SearchContextProvider>
            <GalleryContextProvider 
                source={source}
                sink={sink}
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

    const source = useCloudGallerySource();
    const sink = useCloudGallerySink();

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
