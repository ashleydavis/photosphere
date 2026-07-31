import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import { parse as parseToml } from "smol-toml";
import { readDatabasesConfigHandler, writeDatabasesConfigHandler, registerDatabaseInConfig, buildDatabasesConfigToml } from "../../lib/databases-config.worker";

//
// Tests for the mobile databases.toml handlers.
//
// These run against the real filesystem rather than a mock, because the point of the handlers is the
// bytes they put on disk: mobile and desktop have to agree on the file, so the assertions are about
// the TOML itself (snake_case keys, a `databases` array of tables, `recent_database_names`), not
// about which functions were called.
//
// The handlers reach storage through FileStorage, which resolves relative paths against the process
// working directory on a host and against the app's sandbox root on a device. The tests therefore
// run from a temporary directory, which is what the sandbox root stands in for.
//

//
// The task context the handlers take. They ignore it, so an empty object suffices.
//
const context: any = {};

//
// A temporary working directory standing in for the app's storage sandbox, and the directory the
// test switches back to afterwards.
//
let tempDir: string;
let previousCwd: string;

beforeEach(async () => {
    previousCwd = process.cwd();
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-mobile-config-"));
    process.chdir(tempDir);
});

afterEach(async () => {
    process.chdir(previousCwd);
    await fs.rm(tempDir, { recursive: true, force: true });
});

describe("mobile databases.toml", () => {

    test("reading a config that does not exist yields empty lists", async () => {
        // A fresh install has no file, and that must read as "no databases" rather than fail.
        const result = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
        expect(result).toEqual({ databases: [], recentDatabaseNames: [] });
    });

    test("writing then reading round-trips the databases and recents", async () => {
        await writeDatabasesConfigHandler({
            configPath: "databases.toml",
            databases: [
                { name: "50-assets", description: "", path: "50-assets" },
                { name: "Holiday", description: "Trip photos", path: "holiday" },
            ],
            recentDatabaseNames: ["Holiday", "50-assets"],
        }, context);

        const result = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
        expect(result.databases).toEqual([
            { name: "50-assets", description: "", path: "50-assets" },
            { name: "Holiday", description: "Trip photos", path: "holiday" },
        ]);
        expect(result.recentDatabaseNames).toEqual(["Holiday", "50-assets"]);
    });

    test("the file written uses the same snake_case TOML shape as desktop", async () => {
        await writeDatabasesConfigHandler({
            configPath: "databases.toml",
            databases: [{
                name: "Encrypted",
                description: "",
                path: "enc",
                origin: "s3:bucket:/x",
                s3Key: "default:s3",
                encryptionKey: "default:key",
                geocodingKey: "default:geo",
            }],
            recentDatabaseNames: ["Encrypted"],
        }, context);

        // Parsed as plain TOML, so this asserts the on-disk keys rather than trusting the reader to
        // agree with the writer. These are the keys databases-config.ts writes on desktop.
        const raw = await fs.readFile(path.join(tempDir, "databases.toml"), "utf8");
        const toml = parseToml(raw) as any;
        expect(toml.recent_database_names).toEqual(["Encrypted"]);
        expect(toml.databases).toHaveLength(1);
        expect(toml.databases[0]).toEqual({
            name: "Encrypted",
            description: "",
            path: "enc",
            origin: "s3:bucket:/x",
            s3_key: "default:s3",
            encryption_key: "default:key",
            geocoding_key: "default:geo",
        });
    });

    test("a config written by desktop is read back with the optional fields mapped", async () => {
        // Written by hand in the shape desktop produces, to prove mobile reads desktop's file rather
        // than only its own output.
        await fs.writeFile(path.join(tempDir, "databases.toml"), [
            'recent_database_names = ["Photos"]',
            "",
            "[[databases]]",
            'name = "Photos"',
            'description = "From the desktop"',
            'path = "photos"',
            's3_key = "default:s3"',
            'encryption_key = "default:key"',
            'geocoding_key = "default:geo"',
            'origin = "s3:bucket:/photos"',
            "",
        ].join("\n"), "utf8");

        const result = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
        expect(result.recentDatabaseNames).toEqual(["Photos"]);
        expect(result.databases[0]).toEqual({
            name: "Photos",
            description: "From the desktop",
            path: "photos",
            origin: "s3:bucket:/photos",
            s3Key: "default:s3",
            encryptionKey: "default:key",
            geocodingKey: "default:geo",
        });
    });

    test("optional fields absent from an entry stay absent", async () => {
        await writeDatabasesConfigHandler({
            configPath: "databases.toml",
            databases: [{ name: "Plain", description: "", path: "plain" }],
            recentDatabaseNames: [],
        }, context);

        const raw = await fs.readFile(path.join(tempDir, "databases.toml"), "utf8");
        expect(raw).not.toContain("s3_key");
        expect(raw).not.toContain("encryption_key");
        expect(raw).not.toContain("geocoding_key");
        expect(raw).not.toContain("origin");

        const result = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
        expect(result.databases[0]).toEqual({ name: "Plain", description: "", path: "plain" });
    });

    test("writing replaces the previous contents rather than appending", async () => {
        await writeDatabasesConfigHandler({
            configPath: "databases.toml",
            databases: [{ name: "First", description: "", path: "first" }],
            recentDatabaseNames: ["First"],
        }, context);
        await writeDatabasesConfigHandler({
            configPath: "databases.toml",
            databases: [{ name: "Second", description: "", path: "second" }],
            recentDatabaseNames: [],
        }, context);

        const result = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
        expect(result.databases.map(entry => entry.name)).toEqual(["Second"]);
        expect(result.recentDatabaseNames).toEqual([]);
    });

    test("a missing configPath is rejected", async () => {
        await expect(readDatabasesConfigHandler({ configPath: "" }, context))
            .rejects.toThrow("configPath is required");
        await expect(writeDatabasesConfigHandler({ configPath: "", databases: [], recentDatabaseNames: [] }, context))
            .rejects.toThrow("configPath is required");
    });
});

describe("registering a test database in a config", () => {

    //
    // A config holding two databases of the user's own and one left by an earlier fixture run.
    //
    const existingConfig = [
        'recent_database_names = ["My photos", "test-1-asset"]',
        "",
        "[[databases]]",
        'name = "My photos"',
        'description = "Everything"',
        'path = "/home/alice/photos"',
        's3_key = "default:s3"',
        "",
        "[[databases]]",
        'name = "Holiday"',
        'description = ""',
        'path = "s3:bucket:/holiday"',
        "",
        "[[databases]]",
        'name = "test-1-asset"',
        'description = ""',
        'path = "1-asset"',
        "",
    ].join("\n");

    test("the fixture is registered under a name marking it as a test database", () => {
        const result = parseToml(registerDatabaseInConfig("", "50-assets")) as any;
        expect(result.databases).toEqual([
            { name: "test-50-assets", description: "", path: "50-assets" },
        ]);
    });

    test("the user's own databases are left exactly as they were", () => {
        const result = parseToml(registerDatabaseInConfig(existingConfig, "50-assets")) as any;
        const own = result.databases.filter((entry: any) => !entry.name.startsWith("test-"));
        expect(own).toEqual([
            { name: "My photos", description: "Everything", path: "/home/alice/photos", s3_key: "default:s3" },
            { name: "Holiday", description: "", path: "s3:bucket:/holiday" },
        ]);
    });

    test("the user's own recents are left alone and stale test recents are dropped", () => {
        const result = parseToml(registerDatabaseInConfig(existingConfig, "50-assets")) as any;
        expect(result.recent_database_names).toEqual(["My photos"]);
    });

    test("an earlier fixture is replaced rather than accumulating", () => {
        const result = parseToml(registerDatabaseInConfig(existingConfig, "50-assets")) as any;
        const tests = result.databases.filter((entry: any) => entry.name.startsWith("test-"));
        expect(tests).toEqual([
            { name: "test-50-assets", description: "", path: "50-assets" },
        ]);
    });

    test("registering repeatedly never accumulates entries", () => {
        let config = registerDatabaseInConfig(existingConfig, "50-assets");
        config = registerDatabaseInConfig(config, "1-asset");
        config = registerDatabaseInConfig(config, "no-assets");
        const result = parseToml(config) as any;
        expect(result.databases.map((entry: any) => entry.name)).toEqual([
            "My photos", "Holiday", "test-no-assets",
        ]);
    });

    test("malformed TOML throws rather than replacing the config", () => {
        // Overwriting is at its most destructive exactly when the file cannot be read, so this must
        // never silently start from an empty config.
        expect(() => registerDatabaseInConfig("this is not [ valid toml", "50-assets")).toThrow();
    });

    test("the result is readable by the handler that reads it on device", async () => {
        const config = registerDatabaseInConfig(existingConfig, "50-assets");
        await fs.writeFile(path.join(tempDir, "databases.toml"), config, "utf8");
        const read = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
        expect(read.databases.map(entry => entry.name)).toEqual(["My photos", "Holiday", "test-50-assets"]);
        expect(read.recentDatabaseNames).toEqual(["My photos"]);
    });
});

//
// buildDatabasesConfigToml is what the mobile smoke-test harness renders a device's database list
// with, before the app is launched (apps/smoke-tests/lib/write-databases-config.ts). The file it
// produces has to be exactly what the app reads back, which is what these assert.
//
describe("buildDatabasesConfigToml", () => {

    test("renders the entries and recents in the on-disk snake_case shape", () => {
        const toml = parseToml(buildDatabasesConfigToml(
            [{ name: "Alpha", description: "", path: "alpha", encryptionKey: "alpha-key" }],
            ["Alpha"],
        )) as any;
        expect(toml.databases).toEqual([{ name: "Alpha", description: "", path: "alpha", encryption_key: "alpha-key" }]);
        expect(toml.recent_database_names).toEqual(["Alpha"]);
    });

    test("renders empty lists for a config with nothing in it", () => {
        const toml = parseToml(buildDatabasesConfigToml([], [])) as any;
        expect(toml.databases).toEqual([]);
        expect(toml.recent_database_names).toEqual([]);
    });

    test("the result is readable by the handler that reads it on device", async () => {
        await fs.writeFile(
            path.join(tempDir, "databases.toml"),
            buildDatabasesConfigToml([{ name: "Alpha", description: "", path: "alpha" }], ["Alpha"]),
            "utf8");
        const read = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
        expect(read.databases).toEqual([{ name: "Alpha", description: "", path: "alpha" }]);
        expect(read.recentDatabaseNames).toEqual(["Alpha"]);
    });
});
