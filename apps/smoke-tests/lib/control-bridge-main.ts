//
// Standalone entry point for the host control bridge. Run as a Bun process by the host-driven
// smoke-test harness (common.sh start_app). Kept separate from control-bridge.ts so that
// module is cleanly importable by unit tests without auto-starting a server.
//

import fs from "fs";
import path from "path";
import { runBridgeFromEnv } from "./control-bridge";

runBridgeFromEnv().then((bridge) => {
    //
    // Publish the actually-bound port to a file the harness reads back. The bridge may bind a port
    // other than the requested one (it falls back to an OS-assigned port if the request was taken),
    // so the harness cannot assume the port it asked for. A file write is used rather than stdout
    // because redirected stdout can be block-buffered and not yet flushed when the harness looks.
    //
    const logDir = process.env.PHOTOSPHERE_LOG_DIR;
    if (logDir) {
        fs.writeFileSync(path.join(logDir, "bridge.port"), String(bridge.port));
    }
    console.log(`Control bridge listening on port ${bridge.port}`);
}).catch((error: Error) => {
    console.error(`Failed to start control bridge: ${error.message}`);
    process.exit(1);
});
