//
// Installs the WHATWG `URL` and `URLSearchParams` globals from the maintained `whatwg-url` package.
//
// The AWS SDK builds every request URL through them (`@smithy/url-parser`, `@smithy/util-endpoints`
// and `@smithy/node-http-handler` all call `new URL(...)`), and neither QuickJS nor JavaScriptCore
// provides them. URL parsing decides the host a request is signed for and sent to, so it comes from
// upstream rather than being written here.
//
// This lives apart from `install-globals` because of import order: `whatwg-url` pulls in `tr46`,
// which reads `TextEncoder` while its module body evaluates. Importing it from `install-globals`
// would evaluate it before that module installs the text codecs, and the engine would throw
// "'TextEncoder' is not defined" before any task could run. The worker entry imports
// `install-globals` first, so by the time this module evaluates the codecs are in place.
//

import { URL, URLSearchParams } from "whatwg-url";

//
// Installs `URL` and `URLSearchParams` onto the given scope, leaving any the engine already provides
// alone. The scope parameter exists so unit tests can install onto a fake scope object without
// mutating the real global environment.
//
export function installUrl(globalScope: any): void {
    if (typeof globalScope.URL !== "function") {
        globalScope.URL = URL;
    }
    if (typeof globalScope.URLSearchParams !== "function") {
        globalScope.URLSearchParams = URLSearchParams;
    }
}

// Install immediately on import, so the globals exist before the SDK modules evaluate.
installUrl(globalThis);
