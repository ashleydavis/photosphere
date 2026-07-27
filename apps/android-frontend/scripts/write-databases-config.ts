//
// Writes the app's databases.toml with one database registered, merged into whatever is there.
//
// Called by run-android.sh, which reads the existing file off the device and passes it in, then
// pushes the result back. Registering a database this way is the same move as registering one in
// ~/.config/photosphere/databases.toml on desktop: write the config, the app reads it.
//
// The merge itself is registerDatabaseInConfig in node-api, beside the handlers that read and write
// the file on device, so this script and the app cannot drift on the format. That is also where its
// unit tests are.
//
// Usage: FIXTURE_DB=<name> EXISTING=<toml text> bun write-databases-config.ts <output-file>

import { writeFileSync } from "fs";
import { registerDatabaseInConfig } from "node-api/src/lib/databases-config.worker";

//
// Reads the database name and existing config from the environment, and writes the merged config to
// the file named by the last argument.
//
function main(): void {
    const outputPath = process.argv[process.argv.length - 1];
    if (!outputPath || outputPath.endsWith("write-databases-config.ts")) {
        throw new Error("usage: write-databases-config.ts <output-file>");
    }

    const name = process.env.FIXTURE_DB;
    if (!name) {
        throw new Error("FIXTURE_DB is required");
    }

    writeFileSync(outputPath, registerDatabaseInConfig(process.env.EXISTING ?? "", name));
}

main();
