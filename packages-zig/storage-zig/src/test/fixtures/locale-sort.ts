//
// Sorts names like FileStorage.listFiles does in TypeScript, for the Zig golden test in src/test/locale-compare.test.zig.
// Run as: bun run src/test/fixtures/locale-sort.ts <names-file>
// The names file holds one name per line. Prints the sorted names, one per line.
//
import * as fs from "fs";

//
// Entry point.
//
function main(): void {
    const namesFile = process.argv[2];
    if (!namesFile) {
        console.error("Usage: bun run locale-sort.ts <names-file>");
        process.exit(1);
    }
    const names = fs.readFileSync(namesFile, "utf8").split("\n").filter(name => name.length > 0);
    names.sort((left, right) => left.localeCompare(right, undefined, { numeric: true }));
    process.stdout.write(names.join("\n") + "\n");
}

main();
