//
// Minimal `os` shim for the embedded mobile worker.
//
// node-utils imports `os` for `tmpdir`/`homedir` when resolving config locations. On mobile there is
// no real OS home or temp; both return sandbox-relative directory names so any derived path stays
// inside the native storage root (and resolves to a missing file, which the config loaders treat as
// "not configured"). This is sufficient for the read path, which never writes via these paths.
//

//
// Returns a sandbox-relative temp directory name.
//
export function tmpdir(): string {
    return "tmp";
}

//
// Returns an empty home directory so derived config paths stay sandbox-relative.
//
export function homedir(): string {
    return "";
}

//
// Returns the platform identifier.
//
export function platform(): string {
    return "android";
}

//
// The end-of-line marker.
//
export const EOL = "\n";

//
// The default export mirrors `import os from "os"`.
//
const osModule = { tmpdir, homedir, platform, EOL };

export default osModule;
