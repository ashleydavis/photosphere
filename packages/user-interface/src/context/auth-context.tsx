import axios from "axios";
import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { Spinner } from "../components/spinner";
import { IAuthConfig } from "defs";
import { Auth0Provider } from "@auth0/auth0-react";
import { Auth0ContextProvider } from "./auth-providers/auth0-context";
import { NoAuthContextProvider } from "./auth-providers/no-auth-context";
import { BASE_URL } from "./api-context";

export interface IAuthContext {
    //
    // The mode of the app.
    //
    appMode: string; // "readonly" or "readwrite".

    //
    // Set to true when authentication is enabled.
    //
    isAuthEnabled: boolean;

    //
    // Set to true when loading authentication.
    //
    isLoading: boolean;

    //
    // Set to true when the user is authenticated.
    //
    isAuthenticated: boolean;

    //
    // The authentication error, if one occured.
    //
    error: Error | undefined;

    //
    // Logs in.
    //
    login(): Promise<void>;

    //
    // Logs out.
    //
    logout(): Promise<void>;

    //
    // Gets authendicated configuration for requests.
    //
    getRequestConfig(): Promise<{ headers: any }>;
}

export interface IAuthContextProviderProps {
    //
    // Used to control the login/logout redirect and not rely on the SDK to do the actual redirect.
    //
    openUrl?: (url: string) => Promise<void> | void;

    children: ReactNode | ReactNode[];
}

export const AuthContext = createContext<IAuthContext | undefined>(undefined);

export function AuthContextProvider({ openUrl, children }: IAuthContextProviderProps) {
    const [authConfig, setAuthConfig] = useState<IAuthConfig | undefined>(undefined);
    const [loading, setLoading] = useState<boolean>(true);
    const [error, setError] = useState(undefined);

    useEffect(() => {
        axios.get(`${BASE_URL}/auth/config`) // Fetch auth config.
            .then(response => {
                setAuthConfig(response.data);
                setLoading(false);
            })
            .catch(err => {
                console.error('Failed to fetch auth configuration:');
                console.error(err.stack || err.message || err);
                setError(err);
                setLoading(false);
            });
    }, []);

    if (error) {
        return (
            <div className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0">
                <div className="text-red-500">
                    Error loading authentication configuration.
                </div>
            </div>
        );
    }

    if (loading) {
        return (
            <div className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0">
                <Spinner show={true} />
            </div>
        );
    }

    if (!authConfig) {
        return (
            <div className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0">
                <div className="text-red-500">
                    Unknown authentication configuration.
                </div>
            </div>
        );
    }

    if (authConfig.authMode === "auth0") {
        if (!authConfig.auth0) {
            return (
                <div className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0">
                    <div className="text-red-500">
                        Unknown auth0 configuration.
                    </div>
                </div>
            );
        }

        const redirectUrl = import.meta.env.VITE_AUTH0_REDIRECT_URL || authConfig.auth0.redirectUrl;

        return (
            <Auth0Provider
                domain={authConfig.auth0.domain}
                clientId={authConfig.auth0.clientId}
                authorizationParams={{
                    audience: authConfig.auth0.audience,
                    redirect_uri: redirectUrl,
                }}
                >
                <Auth0ContextProvider
                    appMode={authConfig.appMode}
                    redirectUrl={redirectUrl}
                    openUrl={openUrl}
                    >
                    {children}
                </Auth0ContextProvider>
            </Auth0Provider>
        );
    }

    if (authConfig.authMode === "no-auth") {
        return (
            <NoAuthContextProvider
                appMode={authConfig.appMode}
                >
                {children}
            </NoAuthContextProvider>
        );
    }

    return (
        <div className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0">
            <div className="text-red-500">
                Unknown authentication mode: {authConfig.authMode}.
            </div>
        </div>
    );
}

//
// Use the auth context in a component.
//
export function useAuth(): IAuthContext {
    const context = useContext(AuthContext);
    if (!context) {
        throw new Error(`Auth context is not set! Add AuthContextProvider to the component tree.`);
    }
    return context;
}

