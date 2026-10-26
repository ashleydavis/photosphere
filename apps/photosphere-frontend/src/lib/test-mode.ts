//
// Whether the app is running in test mode, which the core asks for with ?testMode=1 on the page's
// address.
//
// Shared rather than derived where it is needed, because several things turn on it and they have to
// agree: main.tsx patches the console to forward page output to the core, and the renderer log stops
// writing to the console when it does, so that a message forwarded by the patch is not also sent on
// Ziggy's log and written to app.log twice.
//
export function isTestMode(): boolean {
    return typeof window !== 'undefined'
        && new URLSearchParams(window.location.search).get('testMode') === '1';
}
