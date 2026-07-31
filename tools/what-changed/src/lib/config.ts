import { readFile } from "node:fs/promises";
import * as path from "node:path";

//
// The cache directory used when the config does not name one, relative to the config file.
//
const DEFAULT_CACHE_DIR = ".cache/what-changed";

//
// One script the gate can ask the runner for, and the paths that decide whether it needs to run.
//
export interface TargetConfig {
    //
    // The script name handed to the runner.
    //
    name: string;

    //
    // Repository-relative files or directories whose content decides whether this target runs.
    //
    paths: string[];

    //
    // The process.platform values this target can run on. Empty means every platform.
    //
    platforms: string[];
}

//
// The whole gate configuration. Everything project-specific lives here, so the package itself carries
// nothing about any particular project.
//
export interface GateConfig {
    //
    // Where the recorded hashes are kept, relative to the config file's directory.
    //
    cacheDir: string;

    //
    // The command and its fixed arguments. The names of the targets that need to run are appended.
    //
    runnerCommand: string[];

    //
    // Paths watched by every target, for things that change how every suite runs.
    //
    alwaysPaths: string[];

    //
    // File extensions, each including its leading dot, that are left out of the file list entirely.
    // A file whose extension is listed can never make any target run.
    //
    ignoreExtensions: string[];

    //
    // The targets the gate can run.
    //
    targets: TargetConfig[];
}

//
// Parses and validates a gate configuration, throwing an error naming the offending field and value
// for anything malformed. A wrong config must fail loudly: silently falling back to a default would
// mean a suite quietly stops running.
//
export function parseGateConfig(rawJson: string): GateConfig {
    let parsed: any;
    try {
        parsed = JSON.parse(rawJson);
    }
    catch (err: any) {
        throw new Error(`what-changed config is not valid JSON: ${err.message}`);
    }

    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
        throw new Error(`what-changed config must be a JSON object, got ${JSON.stringify(parsed)}`);
    }

    const cacheDir = parsed.cacheDir === undefined ? DEFAULT_CACHE_DIR : parsed.cacheDir;
    if (typeof cacheDir !== "string" || cacheDir.length === 0) {
        throw new Error(`what-changed config field "cacheDir" must be a non-empty string, got ${JSON.stringify(parsed.cacheDir)}`);
    }

    const runnerCommand = parsed.runnerCommand;
    if (!Array.isArray(runnerCommand) || runnerCommand.length === 0) {
        throw new Error(`what-changed config field "runnerCommand" must be a non-empty array, got ${JSON.stringify(runnerCommand)}`);
    }
    for (const argument of runnerCommand) {
        if (typeof argument !== "string" || argument.length === 0) {
            throw new Error(`what-changed config field "runnerCommand" must hold non-empty strings, got ${JSON.stringify(argument)}`);
        }
    }

    const alwaysPaths = parsed.alwaysPaths === undefined ? [] : parsed.alwaysPaths;
    if (!Array.isArray(alwaysPaths)) {
        throw new Error(`what-changed config field "alwaysPaths" must be an array, got ${JSON.stringify(parsed.alwaysPaths)}`);
    }
    for (const watchedPath of alwaysPaths) {
        validateWatchedPath(watchedPath, "alwaysPaths");
    }

    const ignoreExtensions = parsed.ignoreExtensions === undefined ? [] : parsed.ignoreExtensions;
    if (!Array.isArray(ignoreExtensions)) {
        throw new Error(`what-changed config field "ignoreExtensions" must be an array, got ${JSON.stringify(parsed.ignoreExtensions)}`);
    }
    for (const extension of ignoreExtensions) {
        validateIgnoreExtension(extension);
    }

    const rawTargets = parsed.targets;
    if (!Array.isArray(rawTargets) || rawTargets.length === 0) {
        throw new Error(`what-changed config field "targets" must be a non-empty array, got ${JSON.stringify(rawTargets)}`);
    }

    const seenNames = new Set<string>();
    const targets: TargetConfig[] = [];
    for (const rawTarget of rawTargets) {
        targets.push(parseTarget(rawTarget, seenNames));
    }

    return {
        cacheDir,
        runnerCommand,
        alwaysPaths,
        ignoreExtensions,
        targets,
    };
}

//
// Parses and validates one target, recording its name so a duplicate can be rejected.
//
export function parseTarget(rawTarget: any, seenNames: Set<string>): TargetConfig {
    if (typeof rawTarget !== "object" || rawTarget === null || Array.isArray(rawTarget)) {
        throw new Error(`what-changed config target must be an object, got ${JSON.stringify(rawTarget)}`);
    }

    const name = rawTarget.name;
    if (typeof name !== "string" || name.length === 0) {
        throw new Error(`what-changed config target field "name" must be a non-empty string, got ${JSON.stringify(name)}`);
    }
    if (seenNames.has(name)) {
        throw new Error(`what-changed config has a duplicate target name "${name}"`);
    }
    seenNames.add(name);

    const paths = rawTarget.paths;
    if (!Array.isArray(paths) || paths.length === 0) {
        throw new Error(`what-changed config target "${name}" field "paths" must be a non-empty array, got ${JSON.stringify(paths)}`);
    }
    for (const watchedPath of paths) {
        validateWatchedPath(watchedPath, `target "${name}" paths`);
    }

    const platforms = rawTarget.platforms === undefined ? [] : rawTarget.platforms;
    if (!Array.isArray(platforms)) {
        throw new Error(`what-changed config target "${name}" field "platforms" must be an array, got ${JSON.stringify(rawTarget.platforms)}`);
    }
    for (const platform of platforms) {
        if (typeof platform !== "string" || platform.length === 0) {
            throw new Error(`what-changed config target "${name}" field "platforms" must hold non-empty strings, got ${JSON.stringify(platform)}`);
        }
    }

    return {
        name,
        paths,
        platforms,
    };
}

//
// Rejects anything that is not a relative path inside the project. An absolute path or one that
// climbs out with ".." would let the gate watch, and later report on, files outside the repository.
//
export function validateWatchedPath(watchedPath: any, fieldDescription: string): void {
    if (typeof watchedPath !== "string" || watchedPath.length === 0) {
        throw new Error(`what-changed config field "${fieldDescription}" must hold non-empty strings, got ${JSON.stringify(watchedPath)}`);
    }
    if (path.isAbsolute(watchedPath) || watchedPath.startsWith("/")) {
        throw new Error(`what-changed config field "${fieldDescription}" must hold relative paths, got "${watchedPath}"`);
    }
    if (watchedPath.split("/").includes("..")) {
        throw new Error(`what-changed config field "${fieldDescription}" must not contain a ".." segment, got "${watchedPath}"`);
    }
}

//
// Rejects anything that is not a file extension with a leading dot. The dot is required rather than
// added silently, because "ts" could plausibly mean an extension or a directory and guessing wrong
// would quietly stop a suite from running.
//
export function validateIgnoreExtension(extension: any): void {
    if (typeof extension !== "string" || extension.length === 0) {
        throw new Error(`what-changed config field "ignoreExtensions" must hold non-empty strings, got ${JSON.stringify(extension)}`);
    }
    if (!extension.startsWith(".")) {
        throw new Error(`what-changed config field "ignoreExtensions" entries must start with a dot, got "${extension}"`);
    }
    if (extension.length === 1) {
        throw new Error(`what-changed config field "ignoreExtensions" entries must have something after the dot, got "${extension}"`);
    }
    if (extension.includes("/")) {
        throw new Error(`what-changed config field "ignoreExtensions" holds extensions, not paths, got "${extension}"`);
    }
}

//
// Reads a gate configuration from disk and parses it, naming the path when the file cannot be read.
//
export async function loadGateConfig(configPath: string): Promise<GateConfig> {
    let rawJson: string;
    try {
        rawJson = await readFile(configPath, "utf8");
    }
    catch (err: any) {
        throw new Error(`Failed to read the what-changed config at "${configPath}": ${err.message}`);
    }
    return parseGateConfig(rawJson);
}
