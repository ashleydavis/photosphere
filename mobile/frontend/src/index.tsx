import React, { useEffect } from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";
import "./styles.css";
import { Auth0ContextProvider } from "./lib/auth0-context";
import { Auth0Provider, useAuth0 } from "@auth0/auth0-react";
import { NoAuthContextProvider } from "./lib/no-auth-context";
import { Browser } from "@capacitor/browser";
import { App as CapacitorApp } from "@capacitor/app";

const enableAuth = process.env.AUTH_TYPE === "auth0";

const container = document.getElementById('app');
const root = createRoot(container!);

if (enableAuth) {
    // Auth enabled.
    root.render(
        <Auth0Provider
            domain={process.env.AUTH0_DOMAIN as string}
            clientId={process.env.AUTH0_CLIENT_ID as string}
            authorizationParams={{
                audience: process.env.AUTH0_AUDIENCE as string,
                redirect_uri: `${process.env.AUTH0_ORIGIN}/on_login`,
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

