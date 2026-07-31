import { mkdtemp, rm, writeFile } from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { loadGateConfig, parseGateConfig, parseTarget, validateIgnoreExtension, validateWatchedPath } from "../lib/config";

//
// The directory each test writes its throwaway config file into.
//
let tempDir: string;

beforeEach(async () => {
    tempDir = await mkdtemp(path.join(os.tmpdir(), "what-changed-config-"));
});

afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
});

test("parseGateConfig accepts a full valid config and returns every field", () => {
    const config = parseGateConfig(JSON.stringify({
        cacheDir: ".cache/gate",
        runnerCommand: ["./run.sh", "--fast"],
        alwaysPaths: ["package.json"],
        targets: [
            { name: "compile", paths: ["packages"], platforms: ["linux"] },
        ],
    }));

    expect(config.cacheDir).toBe(".cache/gate");
    expect(config.runnerCommand).toEqual(["./run.sh", "--fast"]);
    expect(config.alwaysPaths).toEqual(["package.json"]);
    expect(config.targets).toEqual([{ name: "compile", paths: ["packages"], platforms: ["linux"] }]);
});

test("parseGateConfig applies the defaults for cacheDir, alwaysPaths and platforms", () => {
    const config = parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        targets: [{ name: "compile", paths: ["packages"] }],
    }));

    expect(config.cacheDir).toBe(".cache/what-changed");
    expect(config.alwaysPaths).toEqual([]);
    expect(config.targets[0].platforms).toEqual([]);
});

test("parseGateConfig throws when runnerCommand is missing or empty", () => {
    expect(() => parseGateConfig(JSON.stringify({
        targets: [{ name: "compile", paths: ["packages"] }],
    }))).toThrow(/runnerCommand/);

    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: [],
        targets: [{ name: "compile", paths: ["packages"] }],
    }))).toThrow(/runnerCommand/);
});

test("parseGateConfig throws when targets is missing or empty", () => {
    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
    }))).toThrow(/targets/);

    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        targets: [],
    }))).toThrow(/targets/);
});

test("parseGateConfig throws on a duplicate target name", () => {
    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        targets: [
            { name: "compile", paths: ["packages"] },
            { name: "compile", paths: ["apps"] },
        ],
    }))).toThrow(/duplicate target name "compile"/);
});

test("parseGateConfig throws on a target with an empty paths array", () => {
    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        targets: [{ name: "compile", paths: [] }],
    }))).toThrow(/target "compile" field "paths"/);
});

test("parseGateConfig throws on an absolute path and on a path containing ..", () => {
    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        targets: [{ name: "compile", paths: ["/etc"] }],
    }))).toThrow(/relative paths/);

    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        targets: [{ name: "compile", paths: ["../outside"] }],
    }))).toThrow(/".." segment/);
});

test("parseGateConfig throws on malformed JSON with a message naming the problem", () => {
    expect(() => parseGateConfig("{ not json")).toThrow(/not valid JSON/);
});

test("parseGateConfig throws when the whole document is not an object", () => {
    expect(() => parseGateConfig("[1, 2, 3]")).toThrow(/must be a JSON object/);
    expect(() => parseGateConfig("null")).toThrow(/must be a JSON object/);
    expect(() => parseGateConfig("42")).toThrow(/must be a JSON object/);
});

test("parseGateConfig throws on an empty cacheDir and on one that is not a string", () => {
    expect(() => parseGateConfig(JSON.stringify({
        cacheDir: "",
        runnerCommand: ["./run.sh"],
        targets: [{ name: "compile", paths: ["packages"] }],
    }))).toThrow(/"cacheDir"/);

    expect(() => parseGateConfig(JSON.stringify({
        cacheDir: 7,
        runnerCommand: ["./run.sh"],
        targets: [{ name: "compile", paths: ["packages"] }],
    }))).toThrow(/"cacheDir"/);
});

test("parseGateConfig throws when runnerCommand holds a non-string or an empty string", () => {
    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh", ""],
        targets: [{ name: "compile", paths: ["packages"] }],
    }))).toThrow(/"runnerCommand" must hold non-empty strings/);

    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh", 7],
        targets: [{ name: "compile", paths: ["packages"] }],
    }))).toThrow(/"runnerCommand" must hold non-empty strings/);
});

test("parseGateConfig throws when alwaysPaths is not an array or holds a bad path", () => {
    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        alwaysPaths: "package.json",
        targets: [{ name: "compile", paths: ["packages"] }],
    }))).toThrow(/"alwaysPaths" must be an array/);

    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        alwaysPaths: ["/etc"],
        targets: [{ name: "compile", paths: ["packages"] }],
    }))).toThrow(/alwaysPaths/);
});

test("parseTarget returns a target with platforms defaulted and records the name as seen", () => {
    const seenNames = new Set<string>();

    const target = parseTarget({ name: "compile", paths: ["packages"] }, seenNames);

    expect(target).toEqual({ name: "compile", paths: ["packages"], platforms: [] });
    expect(seenNames.has("compile")).toBe(true);
});

test("parseTarget throws when the target is not an object", () => {
    expect(() => parseTarget(["compile"], new Set<string>())).toThrow(/target must be an object/);
    expect(() => parseTarget(null, new Set<string>())).toThrow(/target must be an object/);
    expect(() => parseTarget("compile", new Set<string>())).toThrow(/target must be an object/);
});

test("parseTarget throws on a missing or empty name", () => {
    expect(() => parseTarget({ paths: ["packages"] }, new Set<string>())).toThrow(/"name"/);
    expect(() => parseTarget({ name: "", paths: ["packages"] }, new Set<string>())).toThrow(/"name"/);
});

test("parseTarget throws when the name is already in the seen set", () => {
    const seenNames = new Set<string>(["compile"]);

    expect(() => parseTarget({ name: "compile", paths: ["packages"] }, seenNames)).toThrow(/duplicate target name "compile"/);
});

test("parseTarget throws when platforms is not an array or holds an empty string", () => {
    expect(() => parseTarget({ name: "compile", paths: ["packages"], platforms: "linux" }, new Set<string>()))
        .toThrow(/"platforms" must be an array/);
    expect(() => parseTarget({ name: "compile", paths: ["packages"], platforms: [""] }, new Set<string>()))
        .toThrow(/"platforms" must hold non-empty strings/);
});

test("validateWatchedPath accepts an ordinary relative path", () => {
    expect(() => validateWatchedPath("src/parser", "test field")).not.toThrow();
    expect(() => validateWatchedPath("package.json", "test field")).not.toThrow();
});

test("validateWatchedPath throws on a non-string or an empty string, naming the field", () => {
    expect(() => validateWatchedPath(7, "test field")).toThrow(/"test field" must hold non-empty strings/);
    expect(() => validateWatchedPath("", "test field")).toThrow(/"test field" must hold non-empty strings/);
});

test("validateWatchedPath throws on an absolute path", () => {
    expect(() => validateWatchedPath("/etc/passwd", "test field")).toThrow(/must hold relative paths/);
});

test("validateWatchedPath throws on any .. segment, not only a leading one", () => {
    expect(() => validateWatchedPath("../outside", "test field")).toThrow(/".." segment/);
    expect(() => validateWatchedPath("src/../../outside", "test field")).toThrow(/".." segment/);
});

test("validateWatchedPath accepts a name that merely starts with dots", () => {
    //
    // "..foo" is a legitimate file name and must not be caught by the ".." segment rule.
    //
    expect(() => validateWatchedPath("..foo", "test field")).not.toThrow();
    expect(() => validateWatchedPath(".githooks", "test field")).not.toThrow();
});

test("parseGateConfig reads ignoreExtensions and defaults it to empty", () => {
    const withList = parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        ignoreExtensions: [".md", ".log"],
        targets: [{ name: "compile", paths: ["src"] }],
    }));
    const without = parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        targets: [{ name: "compile", paths: ["src"] }],
    }));

    expect(withList.ignoreExtensions).toEqual([".md", ".log"]);
    expect(without.ignoreExtensions).toEqual([]);
});

test("parseGateConfig throws when ignoreExtensions is not an array or holds a bad entry", () => {
    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        ignoreExtensions: ".md",
        targets: [{ name: "compile", paths: ["src"] }],
    }))).toThrow(/"ignoreExtensions" must be an array/);

    expect(() => parseGateConfig(JSON.stringify({
        runnerCommand: ["./run.sh"],
        ignoreExtensions: ["md"],
        targets: [{ name: "compile", paths: ["src"] }],
    }))).toThrow(/must start with a dot/);
});

test("validateIgnoreExtension accepts an extension with a leading dot", () => {
    expect(() => validateIgnoreExtension(".md")).not.toThrow();
    expect(() => validateIgnoreExtension(".tar.gz")).not.toThrow();
});

test("validateIgnoreExtension throws on a non-string or an empty string", () => {
    expect(() => validateIgnoreExtension(7)).toThrow(/must hold non-empty strings/);
    expect(() => validateIgnoreExtension("")).toThrow(/must hold non-empty strings/);
});

test("validateIgnoreExtension throws when the leading dot is missing", () => {
    //
    // "ts" could mean an extension or a directory, and guessing wrong would quietly stop a suite
    // running, so the dot is required rather than added silently.
    //
    expect(() => validateIgnoreExtension("md")).toThrow(/must start with a dot/);
});

test("validateIgnoreExtension throws on a bare dot and on anything with a path separator", () => {
    expect(() => validateIgnoreExtension(".")).toThrow(/something after the dot/);
    expect(() => validateIgnoreExtension("docs/.md")).toThrow(/must start with a dot/);
    expect(() => validateIgnoreExtension(".md/x")).toThrow(/extensions, not paths/);
});

test("loadGateConfig reads and parses a config file from disk", async () => {
    const configPath = path.join(tempDir, "what-changed.json");
    await writeFile(configPath, JSON.stringify({
        runnerCommand: ["./run.sh"],
        targets: [{ name: "compile", paths: ["packages"] }],
    }));

    const config = await loadGateConfig(configPath);

    expect(config.targets[0].name).toBe("compile");
});

test("loadGateConfig throws an error naming the path when the file does not exist", async () => {
    const configPath = path.join(tempDir, "nope.json");

    await expect(loadGateConfig(configPath)).rejects.toThrow(configPath);
});
