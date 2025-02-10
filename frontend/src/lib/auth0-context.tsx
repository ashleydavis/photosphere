//
// Useful Auth0 docs:
//
//  https://auth0.com/docs/quickstart/native/ionic-react/01-login
//  https://github.com/auth0-samples/auth0-ionic-samples
//  https://community.auth0.com/t/auth0-callback-url-with-capacitor-native-app/66293
//

import React, { ReactNode, useEffect } from "react";
import { useAuth0 } from "@auth0/auth0-react";
import { AuthContext, IAuthContext } from "user-interface";

export interface IAuth0ContextProviderProps {
    //
    // Used to control the login/logout redirect and not rely on the SDK to do the actual redirect.
    //
    openUrl?: (url: string) => Promise<void> | void;

    children: ReactNode | ReactNode[];
}

export function Auth0ContextProvider({ openUrl, children }: IAuth0ContextProviderProps) {

    const {
        isLoading,
        isAuthenticated,
        error,
        loginWithRedirect,
        logout: _logout,
        getAccessTokenSilently,
    } = useAuth0();

    useEffect(() => {
        validateAuthSettings();
    }, []);

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
                returnTo: `${process.env.AUTH0_ORIGIN}/on_logout`,
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

//
// Make sure auth0 settings are enabled.
//
function validateAuthSettings() {
    checkEnvironmentVariable("AUTH0_DOMAIN", process.env.AUTH0_DOMAIN);
    checkEnvironmentVariable("AUTH0_CLIENT_ID", process.env.AUTH0_CLIENT_ID);
    checkEnvironmentVariable("AUTH0_AUDIENCE", process.env.AUTH0_AUDIENCE);
    checkEnvironmentVariable("AUTH0_ORIGIN", process.env.AUTH0_ORIGIN);
}
