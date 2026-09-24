//
// Generates the golden fixtures used by the Zig tests of api-zig.
// Run with: bun run src/test/fixtures/generate.ts (from packages/api-zig).
//
// Runs the TypeScript saveDatabaseConfig/updateDatabaseConfig against an in-memory storage and
// records the bytes written to .db/config.json, so the Zig tests can check byte-identical output.
//
import * as fs from "fs";
import * as path from "path";
import { saveDatabaseConfig, updateDatabaseConfig } from "../../../../api/src/lib/database-config";

//
// A minimal in-memory stand-in for IStorage (only the methods database-config uses).
//
class MemoryStorage {
    //
    // The files in the storage.
    //
    files = new Map<string, Buffer>();

    async fileExists(filePath: string): Promise<boolean> {
        return this.files.has(filePath);
    }

    async read(filePath: string): Promise<Buffer | undefined> {
        return this.files.get(filePath);
    }

    async write(filePath: string, _contentType: string | undefined, data: Buffer): Promise<void> {
        this.files.set(filePath, data);
    }
}

//
// A scenario: optional initial file contents, then either a save or an update.
//
interface IScenario {
    // Name of the scenario (used by the Zig test).
    name: string;

    // Initial contents of .db/config.json (absent when the file does not exist).
    initial?: string;

    // "save" or "update".
    operation: "save" | "update";

    // The config passed to saveDatabaseConfig or the partial passed to updateDatabaseConfig.
    config: any;
}

const scenarios: IScenario[] = [
    { name: "save-empty", operation: "save", config: {} },
    { name: "save-full", operation: "save", config: { origin: "s3:bucket:/photos", lastReplicatedAt: "2024-01-02T03:04:05.678Z", lastSyncedAt: "2024-02-02T00:00:00.000Z", lastModifiedAt: "2024-03-03T00:00:00.000Z" } },
    { name: "save-escapes", operation: "save", config: { origin: "C:\\photos \"quoted\"\n\ttab é 😀" } },
    { name: "update-missing-file", operation: "update", config: { origin: "/src/db", lastReplicatedAt: "2024-01-02T03:04:05.678Z" } },
    { name: "update-empty-object", initial: "{}", operation: "update", config: { lastModifiedAt: "2024-05-05T00:00:00.000Z" } },
    { name: "update-keeps-order", initial: JSON.stringify({ lastModifiedAt: "old-modified", origin: "old-origin" }, null, 2), operation: "update", config: { origin: "/new/origin", lastReplicatedAt: "2024-01-02T03:04:05.678Z" } },
    { name: "update-keeps-unknown-keys", initial: JSON.stringify({ custom: { nested: [1, 2, "x"], flag: true }, lastSyncedAt: "sync", count: 42, nothing: null }, null, 2), operation: "update", config: { origin: "/o" } },
];

async function main(): Promise<void> {
    const results: any[] = [];
    for (const scenario of scenarios) {
        const storage = new MemoryStorage();
        if (scenario.initial !== undefined) {
            storage.files.set(".db/config.json", Buffer.from(scenario.initial, "utf8"));
        }
        if (scenario.operation === "save") {
            await saveDatabaseConfig(storage as any, scenario.config);
        }
        else {
            await updateDatabaseConfig(storage as any, scenario.config);
        }
        results.push({ ...scenario, expected: storage.files.get(".db/config.json")!.toString("utf8") });
    }
    fs.writeFileSync(path.join(__dirname, "database-config.json"), JSON.stringify(results, null, 4) + "\n");
}

main();
