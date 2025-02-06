import React, { createContext, useContext } from "react";

export interface IAuthContext {

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

export const AuthContext = createContext<IAuthContext | undefined>(undefined);

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

