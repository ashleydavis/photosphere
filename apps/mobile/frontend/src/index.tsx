import React, { useEffect } from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";
import { AuthContextProvider } from "user-interface";
import { useAuth0 } from "@auth0/auth0-react";
import { Browser } from "@capacitor/browser";
import { App as CapacitorApp } from "@capacitor/app";

const container = document.getElementById('app');
const root = createRoot(container!);

root.render(
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
        <App />
    </AuthContextProvider>
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
