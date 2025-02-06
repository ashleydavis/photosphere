import React, { ReactNode } from "react";
import { AuthContext, IAuthContext } from "user-interface";

export interface INoAuthContextProviderProps {
    children: ReactNode | ReactNode[];
}

export function NoAuthContextProvider({ children }: INoAuthContextProviderProps) {

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
