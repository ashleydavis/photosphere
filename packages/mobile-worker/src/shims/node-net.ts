//
// `net` shim for the embedded mobile worker.
//
// node-utils' `find-available-port` imports the `AddressInfo` type from `net`. It is used only as a
// type, but it appears in a value import, so this stub exports a placeholder to satisfy resolution.
// No networking runs in the engine.
//

//
// Placeholder for the `AddressInfo` type used only in type position by find-available-port.
//
export class AddressInfo {}

//
// The default export mirrors `import net from "net"`.
//
const netModule = { AddressInfo };

export default netModule;
