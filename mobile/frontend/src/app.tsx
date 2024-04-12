import React, { useEffect } from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, AuthContextProvider, CloudGallerySourceContextProvider, GalleryContextProvider, Main, SearchContextProvider, UploadContextProvider } from "user-interface";
import { ComputerPage } from "./pages/computer";
import { ComputerGallerySourceContextProvider } from "./context/source/computer-gallery-source-context";
import { ScanContextProvider } from "./context/scan-context";
import { Auth0Provider, useAuth0 } from "@auth0/auth0-react";
import { App as CapacitorApp } from "@capacitor/app";
import { Browser } from "@capacitor/browser";

export function App() {
    return (
        <HashRouter>
            <Auth0Provider
                domain={process.env.AUTH0_DOMAIN as string}
                clientId={process.env.AUTH0_CLIENT_ID as string}
                useRefreshTokens={true}
                useRefreshTokensFallback={false}
                authorizationParams={{
                    audience: process.env.AUTH0_AUDIENCE as string,
                    redirect_uri: `${process.env.AUTH0_ORIGIN}/on_login`,
                }}
                >
                <AuthContextProvider
                    openUrl={async (url: string) => {
                        console.log(`>>>> Opening URL: ${url}`);
                        //
                        // Redirect using Capacitor's Browser plugin
                        // https://auth0.com/docs/quickstart/native/ionic-react/01-login
                        //
                        await Browser.open({
                            url,
                            windowName: "_self"
                        });
                    }}
                    >
                    <HandleAuthCallback />
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
                </AuthContextProvider>
            </Auth0Provider>
       </HashRouter>
    );
}

//
// This component handles the Auth0 callback.
//
function HandleAuthCallback() {
    const { handleRedirectCallback } = useAuth0();

    useEffect(() => {
        // Handles the 'appUrlOpen' event and calls `handleRedirectCallback`.
        CapacitorApp.addListener('appUrlOpen', async ({ url }) => {
            console.log(`>>>> Handling appUrlOpen for URL: ${url}`);
            if (url.includes('state') && (url.includes('code') || url.includes('error'))) {
                await handleRedirectCallback(url);
            }

            // No-op on Android.
            await Browser.close();
        });
    }, [handleRedirectCallback]);
    
    return <></>;
}