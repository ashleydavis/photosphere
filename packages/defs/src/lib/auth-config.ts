//
// Configuration for Auth0.
//
export interface IAuth0Config {
    domain: string; // Details from your Auth0 account.
    clientId: string;
    audience: string;
    redirectUrl: string;
}

//
// Configuration for authentication.
//
export interface IAuthConfig {
    //
    // The mode of the app.
    //
    appMode: string; // "readonly" or "readwrite".

    //
    // The mode of authentication.
    //
    authMode: string; // "auth0" or "no-auth".

    //
    // When authMode is "auth0", this is the configuration for Auth0.
    //
    auth0?: IAuth0Config;
}