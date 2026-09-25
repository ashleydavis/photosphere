//
// Generates the golden fixtures used by the Zig tests of utils-zig.
// Run with: bun run src/test/fixtures/generate.ts (from packages/utils-zig).
//
import * as fs from "fs";
import * as path from "path";
import { TestUuidGenerator } from "../../../../utils/src/lib/test-uuid-generator";

//
// Counters to generate UUIDs for: the first few ids plus large counters that exercise
// JavaScript float multiplication and int32/uint32 conversions.
//
const counters: number[] = [];
for (let counter = 1; counter <= 50; counter++) {
    counters.push(counter);
}
counters.push(
    100, 1000, 65535, 65536, 123456, 1000000, 2097151, 2097152, 3000000, 10000000,
    123456789, 2147483647, 2147483648, 2863311530, 4294967295, 4294967296, 4294967297,
    1099511627776, 9007199254740991
);

const generator: any = new TestUuidGenerator();
const fixture = counters.map(counter => ({ counter, uuid: generator.generateDeterministicUuid(counter) }));
fs.writeFileSync(path.join(__dirname, "test-uuid-generator.json"), JSON.stringify(fixture, null, 4) + "\n");
