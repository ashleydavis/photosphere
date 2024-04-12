import React, { createContext, ReactNode, useContext, useEffect, useRef } from "react";
import { useAuth0, User } from "@auth0/auth0-react";

export interface IAuthContext {

    //
    // Set to true when loading authentication.
    //
    isLoading: boolean;

    //
    // Set to true when authenticated.
    //
    isAuthenticated: boolean;

    //
    // The logged in user.
    //
    user: User | undefined;

    //
    // The authentication error, if one occured.
    //
    error: Error | undefined;

    //
    // Loads the users access token.
    //
    loadToken(): Promise<void>;

    //
    // Gets an access token for the user.
    //
    getToken(): string;

    //
    // Logs in.
    //
    login(): Promise<void>;

    //
    // Logs out.
    //
    logout(): Promise<void>;


}

const AuthContext = createContext<IAuthContext | undefined>(undefined);

export interface IAuthContextProviderProps {
    //
    // Used to control the login/logout redirect and not rely on the SDK to do the actual redirect.
    //
    openUrl?: (url: string) => Promise<void> | void;

    children: ReactNode | ReactNode[];
}

export function AuthContextProvider({ openUrl, children }: IAuthContextProviderProps) {

    const {
        isLoading,
        isAuthenticated,
        user,
        error,
        loginWithRedirect,
        logout: _logout,
        getAccessTokenSilently,
    } = useAuth0();

    useEffect(() => {
        validateAuthSettings();
    }, []);

    useEffect(() => {
        if (isAuthenticated) {
            console.log(`User is authenticated, loading access token.`);
            loadToken()
                .then(() => {
                    console.log(`Access token loaded.`);                
                })
                .catch(error => {
                    token.current = undefined;
                    console.error(`Error loading access token:`);
                    console.error(error);
                });
        }
        else {
            console.log(`User is not authenticated, clearing access token.`)
            token.current = undefined;
        }
    }, [isAuthenticated]);
    
    //
    // The user's access token.
    //
    let token = useRef<string | undefined>(undefined);

    //
    // Loads the users access token.
    //
    async function loadToken(): Promise<void> {
        if (!token.current) {
            const isProd = process.env.NODE_ENV !== "development" && process.env.NODE_ENV !== "test";
            if (isProd) {
                token.current = await getAccessTokenSilently();
            }
            else {
                token.current = "testing-token";
            }
        }
    }

    function stackTrace() {
        function getStackTrace() {
            const error = new Error();
            return error.stack;
        }
        
        console.log(getStackTrace());
    }

    //
    // Gets an access token for the user.
    //
    function getToken(): string {
        if (!token.current) {
            console.error(`Access token is not loaded!`);
            stackTrace();
            throw new Error(`Access token is not loaded!`);
        }
        return token.current;
    }

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

    const value: IAuthContext = {
        isLoading,
        isAuthenticated,
        user,
        error,
        loadToken,
        getToken,
        login,
        logout,
    };
    
    return (
        <AuthContext.Provider value={value} >
            {children}
        </AuthContext.Provider>
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
