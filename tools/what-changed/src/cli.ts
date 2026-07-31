import { runGate } from "./lib/gate";

//
// The entry point. It holds nothing but the wiring from the real process to the flow in gate.ts, so
// there is nothing here that a test would want to reach. Nothing else may import this file: it runs
// the gate on load.
//
runGate(process.argv.slice(2), process.cwd(), process.platform)
    .then(exitCode => {
        process.exit(exitCode);
    })
    .catch(err => {
        console.error(err.message);
        process.exit(1);
    });
