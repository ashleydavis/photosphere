import React, { useEffect } from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";
import "./styles.css";
import { Auth0ContextProvider, NoAuthContextProvider } from "user-interface";
import { Auth0Provider, useAuth0 } from "@auth0/auth0-react";
import { Browser } from "@capacitor/browser";
import { App as CapacitorApp } from "@capacitor/app";

const enableAuth = import.meta.env.VITE_AUTH_TYPE === "auth0";

const container = document.getElementById('app');
const root = createRoot(container!);

if (enableAuth) {
    // Auth enabled.
    root.render(
        <Auth0Provider
            domain={import.meta.env.VITE_AUTH0_DOMAIN as string}
            clientId={import.meta.env.VITE_AUTH0_CLIENT_ID as string}
            authorizationParams={{
                audience: import.meta.env.VITE_AUTH0_AUDIENCE as string,
                redirect_uri: `${import.meta.env.VITE_AUTH0_ORIGIN}/on_login`,
            }}
            >
            <Auth0ContextProvider
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
                <App />
            </Auth0ContextProvider>
        </Auth0Provider>
    );

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
}
else {
    // Auth disabled.
    root.render(
        <NoAuthContextProvider>
            <App />
        </NoAuthContextProvider>
    );
}

