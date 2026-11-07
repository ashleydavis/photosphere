//
// Loads or dumps YAML with js-yaml for the yaml.zig parity tests.
// Usage: bun run yaml-ts.ts load <file>   -> prints JSON.stringify(yaml.load(text))
//        bun run yaml-ts.ts dump <json>   -> prints yaml.dump(JSON.parse(json)) as a JSON string
//
import yaml from "js-yaml";
import { readFileSync } from "fs";

const [command, argument] = process.argv.slice(2);
if (command === "load") {
    console.log(JSON.stringify(yaml.load(readFileSync(argument, "utf8"))));
}
else if (command === "dump") {
    console.log(JSON.stringify(yaml.dump(JSON.parse(argument))));
}
else {
    throw new Error(`Unknown command: ${command}`);
}
