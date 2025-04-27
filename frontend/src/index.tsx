import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";
import "./styles.css";
import { Auth0Provider } from "@auth0/auth0-react";
import { Auth0ContextProvider } from "./lib/auth0-context";
import { NoAuthContextProvider } from "./lib/no-auth-context";

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
            <Auth0ContextProvider>
                <App />
            </Auth0ContextProvider>
        </Auth0Provider>
    );
}
else {
    // Auth disabled.
    root.render(
        <NoAuthContextProvider>
            <App />
        </NoAuthContextProvider>
    );
}

//
// Register the service worker.
//
// https://css-tricks.com/add-a-service-worker-to-your-site/
//
if (navigator && navigator.serviceWorker) {
    window.addEventListener('load', () => {
        navigator.serviceWorker.register('service-worker.js')
            .catch(err => {
                console.error(`Failed to register the service worker:`);
                console.error(err);
            });
    });
}