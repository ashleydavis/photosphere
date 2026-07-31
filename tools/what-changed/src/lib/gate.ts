import * as path from "node:path";
import { loadCache, PassedFileHashes, pruneFileHashes, savePassedFileHashes, saveFileHashes, saveTargetHashes, TargetHashes } from "./cache-store";
import { diffFileHashes, formatChangedFiles, toPassedFileHashes } from "./changed-files";
import { helpText, parseCliArgs } from "./cli-args";
import { loadGateConfig } from "./config";
import { hashFiles } from "./file-hash";
import { filterIgnoredFiles, isIgnoredFile, listRepoFiles } from "./list-files";
import { buildTree } from "./merkle";
import { planTargets, TargetPlan } from "./plan";
import { runCommand } from "./run-command";

//
// The whole flow, returning the exit code the process should use. The working directory and the
// platform are arguments rather than reads of `process`, so the flow can be driven against a
// throwaway directory and any platform string without touching the real process state.
//
export async function runGate(argv: string[], cwd: string, platform: string): Promise<number> {
    const options = parseCliArgs(argv);
    if (options.showHelp) {
        console.log(helpText());
        return 0;
    }

    const configPath = path.resolve(cwd, options.configPath);
    const rootDir = path.dirname(configPath);
    const config = await loadGateConfig(configPath);

    const knownNames = new Set(config.targets.map(target => target.name));
    for (const requestedName of options.targetNames) {
        if (!knownNames.has(requestedName)) {
            throw new Error(`"${requestedName}" is not a target in "${configPath}". Known targets: ${Array.from(knownNames).join(", ")}`);
        }
    }

    const cacheDir = path.resolve(rootDir, config.cacheDir);
    const cache = await loadCache(cacheDir);

    const filePaths = filterIgnoredFiles(await listRepoFiles(rootDir), config.ignoreExtensions);
    const fileHashes = await hashFiles(rootDir, filePaths, cache.fileHashes);

    //
    // The per-file hashes are only an optimisation, so they are saved whatever the tests go on to do.
    //
    await saveFileHashes(cacheDir, pruneFileHashes(cache.fileHashes, filePaths));

    if (options.filesOnly) {
        //
        // The baseline is filtered by the same rule as the file list. Without this, adding an
        // extension to ignoreExtensions would report every already-recorded file of that type as
        // deleted on the next run.
        //
        reportChangedFiles(fileHashes, filterIgnoredBaseline(cache.passedFileHashes, config.ignoreExtensions));
        return 0;
    }

    const tree = buildTree(fileHashes);
    const plans = planTargets(config, tree, cache.targetHashes, platform, options.targetNames, options.force);

    reportPlans(plans);

    if (options.planOnly) {
        return 0;
    }

    const toRun = plans.filter(plan => plan.shouldRun);

    //
    // Recording by hand goes through exactly the same function as a passing run, so the two can never
    // drift apart. It records the targets that would have run, which is what "these tests are good on
    // this tree" means.
    //
    if (options.baselineOnly) {
        await recordPassingRun(cacheDir, cache.targetHashes, toRun, fileHashes);
        console.log("");
        console.log(`Recorded the current tree as the baseline for ${toRun.length} target(s): ${toRun.map(plan => plan.name).join(", ") || "none"}.`);
        return 0;
    }
    if (toRun.length === 0) {
        console.log("");
        console.log("Nothing to run: every target is up to date. Use --force to run them anyway.");
        return 0;
    }

    console.log("");
    const exitCode = await runCommand([...config.runnerCommand, ...toRun.map(plan => plan.name)], rootDir);
    if (exitCode !== 0) {
        return exitCode;
    }

    //
    // Recorded all-or-nothing, and from the hashes computed before the run rather than a fresh read.
    // The runner kills the remaining lanes on the first failure so there is no trustworthy per-script
    // result to record, and hashes read after the run would mark an edit made during the run as
    // tested.
    //
    await recordPassingRun(cacheDir, cache.targetHashes, toRun, fileHashes);
    return 0;
}

//
// Writes everything a passing run records: the watched-path hashes for each target that ran, merged
// into whatever was already there, and the file-level baseline that --files compares against. Both
// come from the hashes computed before the run, so they describe the tree that was actually tested
// rather than one re-read afterwards.
//
export async function recordPassingRun(cacheDir: string, previousTargetHashes: TargetHashes, recorded: TargetPlan[], fileHashes: Map<string, string>): Promise<void> {
    const targetHashes: TargetHashes = { ...previousTargetHashes };
    for (const plan of recorded) {
        targetHashes[plan.name] = plan.pathHashes;
    }
    await saveTargetHashes(cacheDir, targetHashes);
    await savePassedFileHashes(cacheDir, toPassedFileHashes(fileHashes));
}

//
// Drops the ignored extensions from a recorded baseline, so a change to ignoreExtensions does not read
// as a pile of deletions on the next run.
//
export function filterIgnoredBaseline(baseline: PassedFileHashes, ignoreExtensions: string[]): PassedFileHashes {
    if (ignoreExtensions.length === 0) {
        return baseline;
    }
    const filtered: PassedFileHashes = {};
    for (const [relativePath, hash] of Object.entries(baseline)) {
        if (!isIgnoredFile(relativePath, ignoreExtensions)) {
            filtered[relativePath] = hash;
        }
    }
    return filtered;
}

//
// Prints every file that differs from the last passing run, with its hash. This is the view for
// "what have I actually touched", as opposed to the per-target decision reportPlans gives.
//
export function reportChangedFiles(fileHashes: Map<string, string>, baseline: PassedFileHashes): void {
    if (Object.keys(baseline).length === 0) {
        console.log(`No passing run recorded yet, so there is no baseline to compare against. ${fileHashes.size} file(s) in the working tree.`);
        return;
    }

    const changes = diffFileHashes(fileHashes, baseline);
    if (changes.length === 0) {
        console.log(`No files have changed since the last passing run. ${fileHashes.size} file(s) checked.`);
        return;
    }

    console.log("Changed since the last passing run:");
    for (const line of formatChangedFiles(changes)) {
        console.log(line);
    }
    console.log("");
    console.log(`${changes.length} changed, ${fileHashes.size} file(s) checked.`);
}

//
// Prints one line per considered target saying whether it will run and why. This is the output that
// tells the user why their commit is or is not running a given suite.
//
export function reportPlans(plans: TargetPlan[]): void {
    if (plans.length === 0) {
        console.log("No targets matched.");
        return;
    }

    console.log("What changed:");
    for (const plan of plans) {
        console.log(`  ${plan.shouldRun ? "RUN " : "SKIP"}  ${plan.name}  (${plan.reason})${describeChangedPaths(plan)}`);
    }
}

//
// Names the watched paths that changed, so a run is always traceable back to an edit. Exported so
// the formatting can be tested without capturing console output.
//
export function describeChangedPaths(plan: TargetPlan): string {
    if (plan.changedPaths.length === 0) {
        return "";
    }
    return `: ${plan.changedPaths.join(", ")}`;
}
