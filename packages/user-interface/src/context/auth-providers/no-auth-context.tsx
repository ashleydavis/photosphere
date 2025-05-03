import React, { ReactNode } from "react";
import { AuthContext, IAuthContext } from "user-interface";

export interface INoAuthContextProviderProps {
    //
    // The mode of the app.
    //
    appMode: string; // "readonly" or "readwrite".

    //
    // The Google API key for reverse geocoding, if provided.
    //
    googleApiKey?: string;

    children: ReactNode | ReactNode[];
}

export function NoAuthContextProvider({ appMode, googleApiKey, children }: INoAuthContextProviderProps) {

    //
    // Logs in.
    //
    async function login(): Promise<void> {
        // No auth.
    }

    //
    // Logs out.
    //
    async function logout(): Promise<void> {
        // No auth.
    }

    //
    // Gets authendicated configuration for requests.
    //
    async function getRequestConfig(): Promise<{ headers: any }> {
        return {
            headers: {},
        };
    }

    const value: IAuthContext = {
        appMode,
        googleApiKey,
        isAuthEnabled: false,
        isLoading: false,
        isAuthenticated: true,
        error: undefined,
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
