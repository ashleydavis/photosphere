//
// Prints the names of the package.json scripts that run tests or smoke tests, one per line.
//
// Used by scripts/check-flaky-tests.sh to offer the runnable suites. There is no shell answer,
// because picking keys out of package.json means parsing JSON, and parsing JSON with grep or sed
// breaks the moment a value contains a brace or a quote.
//
// A script counts when its name starts with "test" or "smoke", or contains ":test" or ":smoke", and
// does not mention "watch", because a watch script never terminates and so can never be run this way.
//
// Usage: bun scripts/list-test-scripts.ts --file <path to package.json>
//

import { readFileSync } from "node:fs";

//
// Matches a script name that names a test or smoke suite.
//
const TEST_SCRIPT_PATTERN = /(^|:)(test|smoke)/;

//
// Matches a script name that watches rather than running once.
//
const WATCH_SCRIPT_PATTERN = /watch/;

//
// Reads a required `--name value` argument, failing loudly and naming it when absent.
//
function requiredArg(argv: string[], name: string): string {
    const index = argv.indexOf(`--${name}`);
    if (index === -1 || index + 1 >= argv.length) {
        throw new Error(`Missing required argument --${name}`);
    }
    return argv[index + 1];
}

const argv = process.argv.slice(2);
const packageJson = JSON.parse(readFileSync(requiredArg(argv, "file"), "utf8"));
const scripts = packageJson.scripts ?? {};

for (const scriptName of Object.keys(scripts)) {
    if (TEST_SCRIPT_PATTERN.test(scriptName) && !WATCH_SCRIPT_PATTERN.test(scriptName)) {
        console.log(scriptName);
    }
}
