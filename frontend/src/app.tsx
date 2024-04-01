import React from "react";
import { BrowserRouter } from "react-router-dom";
import { Main, ApiContextProvider, UploadContextProvider, CloudGallerySourceContextProvider, SearchContextProvider } from "user-interface";
import { Auth0Provider } from "@auth0/auth0-react";

export function App() {
    return (
        <BrowserRouter>
            <Auth0Provider
                domain="photosphere-dev.au.auth0.com"
                clientId="PKeSJKF9c130lsllhbLwPAHJGFLLeR4P"
                authorizationParams={{
                    audience: 'https://photosphere-dev',
                    redirect_uri: `${window.location.origin}/on_login`,
                }}
                >
                <ApiContextProvider>
                    <SearchContextProvider>
                        <CloudGallerySourceContextProvider>
                            <UploadContextProvider>
                                <Main />
                            </UploadContextProvider>
                        </CloudGallerySourceContextProvider>
                    </SearchContextProvider>
                </ApiContextProvider>
            </Auth0Provider>
        </BrowserRouter>
    );
}
