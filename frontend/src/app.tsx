import React from "react";
import { BrowserRouter } from "react-router-dom";
import { Main, ApiContextProvider, UploadContextProvider, CloudGallerySourceContextProvider, SearchContextProvider, AuthContextProvider } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";

export function App() {
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
                <AuthContextProvider>
                    <ApiContextProvider>
                        <SearchContextProvider>
                            <CloudGallerySourceContextProvider>
                                <UploadContextProvider>
                                    <Main />
                                </UploadContextProvider>
                            </CloudGallerySourceContextProvider>
                        </SearchContextProvider>
                    </ApiContextProvider>
                </AuthContextProvider>
            </Auth0Provider>
        </BrowserRouter>
    );
}
