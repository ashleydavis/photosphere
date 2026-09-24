//
// Runs the TypeScript databases-config functions for the Zig parity tests.
// Usage (PHOTOSPHERE_CONFIG_DIR selects the config directory):
//   bun run databases-config-ts.ts save <config json>   writes databases.toml with saveDatabasesConfig
//   bun run databases-config-ts.ts load                 prints loadDatabasesConfig() as JSON
//

import { saveDatabasesConfig, loadDatabasesConfig } from "node-api";

//
// Runs the requested operation.
//
async function main(): Promise<void> {
    const [operation, configJson] = process.argv.slice(2);
    if (operation === "save") {
        await saveDatabasesConfig(JSON.parse(configJson));
    }
    else if (operation === "load") {
        console.log(JSON.stringify(await loadDatabasesConfig()));
    }
    else {
        throw new Error(`Unknown operation: ${operation}`);
    }
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
