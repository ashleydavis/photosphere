//
// Useful Auth0 docs:
//
//  https://auth0.com/docs/quickstart/native/ionic-react/01-login
//  https://github.com/auth0-samples/auth0-ionic-samples
//  https://community.auth0.com/t/auth0-callback-url-with-capacitor-native-app/66293
//

import React, { ReactNode, useEffect } from "react";
import { useAuth0 } from "@auth0/auth0-react";
import { AuthContext, IAuthContext } from "../auth-context"

export interface IAuth0ContextProviderProps {
    //
    // The mode of the app.
    //
    appMode: string; // "readonly" or "readwrite".

    //
    // The URL to redirect to after login/logout.
    //
    redirectUrl: string;

    //
    // Used to control the login/logout redirect and not rely on the SDK to do the actual redirect.
    //
    openUrl?: (url: string) => Promise<void> | void;

    children: ReactNode | ReactNode[];
}

export function Auth0ContextProvider({ appMode, redirectUrl, openUrl, children }: IAuth0ContextProviderProps) {

    const {
        isLoading,
        isAuthenticated,
        error,
        loginWithRedirect,
        logout: _logout,
        getAccessTokenSilently,
    } = useAuth0();

    //
    // Logs in.
    //
    async function login(): Promise<void> {
        await loginWithRedirect({
            openUrl,
        });
    }

    //
    // Logs out.
    //
    async function logout(): Promise<void> {
        _logout({
            logoutParams: {
                returnTo: redirectUrl,
            },
            openUrl,
        });
    }

    //
    // Gets authendicated configuration for requests.
    //
    async function getRequestConfig(): Promise<{ headers: any }> {
        const token = await getAccessTokenSilently();
        return { 
            headers: {
                Authorization: `Bearer ${token}`,
            } ,
        };
    }

    const value: IAuthContext = {
        appMode,
        isAuthEnabled: true,
        isLoading: isLoading,
        isAuthenticated: isAuthenticated,
        error,
        login,
        logout,
        getRequestConfig,
    };

    return (
        <AuthContext.Provider value={value} >
            {children}
        </AuthContext.Provider>
    );
}

//
// Check an environment variable.
//
function checkEnvironmentVariable(name: string, value: any): void {
    if (!value) {
        throw new Error(`Environment variable ${name} is not set.`);
    }
}
