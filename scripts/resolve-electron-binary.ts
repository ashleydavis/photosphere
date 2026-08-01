//
// Prints the absolute path of the Electron executable a given directory would launch.
//
// The electron npm package exports that path as its module value, and resolving a node module is not
// something shell can do: the package may be hoisted to the workspace root or kept in the app's own
// node_modules, and only the module resolver knows which.
//
// The directory to resolve from is passed in rather than taken from the working directory, because
// resolution is relative to the importing file, and this file lives in scripts/ rather than in the
// app being launched.
//
// Usage: bun scripts/resolve-electron-binary.ts --from <directory>
//

import { createRequire } from "node:module";
import * as path from "node:path";

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
const resolveFromDir = requiredArg(argv, "from");

// createRequire wants a file inside the directory to resolve from, not the directory itself. The
// file does not have to exist; only its directory is used to anchor the search.
const requireFrom = createRequire(path.join(path.resolve(resolveFromDir), "resolve-anchor.js"));
const electronBinaryPath = requireFrom("electron");
if (typeof electronBinaryPath !== "string") {
    throw new Error(`The electron package resolved from "${resolveFromDir}" did not export a path.`);
}
process.stdout.write(electronBinaryPath);
