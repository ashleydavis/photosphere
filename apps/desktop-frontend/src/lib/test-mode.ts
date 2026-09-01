//
// Whether the app is running in test mode, which the main process asks for with ?testMode=1 on the
// renderer's URL.
//
// Shared rather than derived where it is needed, because two things now turn on it and they have to
// agree: index.tsx patches the console to forward renderer output to the main process, and the
// renderer log stops writing to the console when it does, so that a message forwarded by the patch is
// not also forwarded over IPC and written to app.log twice.
//
export function isTestMode(): boolean {
    return typeof window !== 'undefined'
        && new URLSearchParams(window.location.search).get('testMode') === '1';
}
