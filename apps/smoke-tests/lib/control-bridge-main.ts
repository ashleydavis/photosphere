//
// Standalone entry point for the host control bridge. Run as a Bun process by the host-driven
// smoke-test harness (common.sh start_app). Kept separate from control-bridge.ts so that
// module is cleanly importable by unit tests without auto-starting a server.
//

import { runBridgeFromEnv } from "./control-bridge";

runBridgeFromEnv().then((bridge) => {
    console.log(`Control bridge listening on port ${bridge.port}`);
}).catch((error: Error) => {
    console.error(`Failed to start control bridge: ${error.message}`);
    process.exit(1);
});
