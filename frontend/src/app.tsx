import React from "react";
import { BrowserRouter } from "react-router-dom";
import { Main, ApiContextProvider, UploadContextProvider, CloudGallerySourceContextProvider, SearchContextProvider, AuthContextProvider, isProduction, CloudGallerySinkContextProvider } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";

//
// Default setup for the app.
//
function DefaultSetup() {
    return (
        <AuthContextProvider>
            <ApiContextProvider>
                <SearchContextProvider>
                    <CloudGallerySourceContextProvider>
                        <CloudGallerySinkContextProvider>
                            <UploadContextProvider>
                                <Main />
                            </UploadContextProvider>
                        </CloudGallerySinkContextProvider>
                    </CloudGallerySourceContextProvider>
                </SearchContextProvider>
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
                    <DefaultSetup />
                </Auth0Provider>
            </BrowserRouter>
        );
    }
    else {
        // Setup for dev and testing with no authentication.
        return (
            <BrowserRouter>
                <DefaultSetup />
            </BrowserRouter>
        );
    }
}
