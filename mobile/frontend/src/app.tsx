import React from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, CloudGallerySourceContextProvider, GalleryContextProvider, Main, SearchContextProvider, UploadContextProvider } from "user-interface";
import { ComputerPage } from "./pages/computer";
import { ComputerGallerySourceContextProvider } from "./context/source/computer-gallery-source-context";
import { ScanContextProvider } from "./context/scan-context";
import { Auth0Provider } from "@auth0/auth0-react";

export function App() {
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
                <ApiContextProvider>
                    <SearchContextProvider>
                        <CloudGallerySourceContextProvider>
                            <ScanContextProvider>
                                <ComputerGallerySourceContextProvider>
                                    <UploadContextProvider>
                                            <Main
                                                computerPage={<ComputerPage />} 
                                                />
                                    </UploadContextProvider>
                                </ComputerGallerySourceContextProvider>
                            </ScanContextProvider>
                        </CloudGallerySourceContextProvider>
                    </SearchContextProvider>
                </ApiContextProvider>
            </Auth0Provider>
       </HashRouter>
    );
}
