import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";
import "./styles.css";
import { Auth0Provider } from "@auth0/auth0-react";
import { Auth0ContextProvider } from "./lib/auth0-context";
import { NoAuthContextProvider } from "./lib/no-auth-context";

const isProduction = (process.env.NODE_ENV !== "development" && process.env.NODE_ENV !== "test")
const enableAuth = process.env.AUTH_TYPE === "auth0" && isProduction;

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


