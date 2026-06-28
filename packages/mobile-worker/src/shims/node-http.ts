//
// `http` shim for the embedded mobile worker.
//
// node-utils' `find-available-port` helper (pulled in via the node-utils barrel) imports
// `createServer` from `http`. Nothing on the read path runs a server, so this stub satisfies the
// import and throws the loud NOT IMPLEMENTED error if a server is ever started in the engine.
//

//
// Starting an HTTP server is not available in the embedded engine; fails loudly.
//
export function createServer(): never {
    throw new Error(`NOT IMPLEMENTED: http.createServer is not available in the mobile worker. Implement it ASAP.`);
}

//
// The default export mirrors `import http from "http"`.
//
const httpModule = { createServer };

export default httpModule;
