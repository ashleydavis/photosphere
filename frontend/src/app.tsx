import React from "react";
import { HashRouter } from "react-router-dom";
import { AppContextProvider, Main,  ApiContextProvider, UploadContextProvider, 
    AuthContextProvider, enableAuth, GalleryContextProvider, 
    IndexeddbContextProvider, AssetDatabaseProvider 
    } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";

function GallerySetup() {
    return (
        <AssetDatabaseProvider>
            <GalleryContextProvider>
                <UploadContextProvider>
                    <Main />
                </UploadContextProvider>
            </GalleryContextProvider>
        </AssetDatabaseProvider>
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
    if (enableAuth) {
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

