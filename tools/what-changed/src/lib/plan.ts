import { PathHashes, TargetHashes } from "./cache-store";
import { GateConfig, TargetConfig } from "./config";
import { hashForPath, TreeNode } from "./merkle";

//
// Why a target was or was not chosen to run. Reported to the user so a skipped suite is never a
// mystery.
//
export type PlanReason = "forced" | "never-passed" | "changed" | "unchanged" | "wrong-platform";

//
// The decision made about one target.
//
export interface TargetPlan {
    //
    // The target's name, which is what gets handed to the runner.
    //
    name: string;

    //
    // The freshly computed hash of every path this target watches, ready to be recorded if the run
    // passes.
    //
    pathHashes: PathHashes;

    //
    // Whether this target needs to run.
    //
    shouldRun: boolean;

    //
    // Why that decision was made.
    //
    reason: PlanReason;

    //
    // The watched paths whose hash differs from the recorded one. Empty unless the reason is
    // "changed".
    //
    changedPaths: string[];
}

//
// Returns every path a target watches: its own paths plus the ones every target watches.
//
export function watchedPathsFor(config: GateConfig, target: TargetConfig): string[] {
    const merged = new Set<string>([...target.paths, ...config.alwaysPaths]);
    return Array.from(merged).sort();
}

//
// Decides which targets need to run. Pure, so the whole gating rule can be tested without touching a
// disk or a clock.
//
export function planTargets(config: GateConfig, tree: TreeNode, previous: TargetHashes, platform: string, requestedNames: string[], force: boolean): TargetPlan[] {
    const requested = new Set(requestedNames);
    const considered = requestedNames.length === 0
        ? config.targets
        : config.targets.filter(target => requested.has(target.name));

    return considered.map(target => planTarget(config, tree, previous, platform, target, force));
}

//
// Decides whether one target needs to run, computing its watched-path hashes either way so the caller
// never has to recompute them.
//
export function planTarget(config: GateConfig, tree: TreeNode, previous: TargetHashes, platform: string, target: TargetConfig, force: boolean): TargetPlan {
    const watchedPaths = watchedPathsFor(config, target);
    const pathHashes: PathHashes = {};
    for (const watchedPath of watchedPaths) {
        pathHashes[watchedPath] = hashForPath(tree, watchedPath);
    }

    //
    // The platform check comes first, and beats --force. A suite whose toolchain is not on this
    // machine cannot be made to run by asking harder.
    //
    if (target.platforms.length > 0 && !target.platforms.includes(platform)) {
        return {
            name: target.name,
            pathHashes,
            shouldRun: false,
            reason: "wrong-platform",
            changedPaths: [],
        };
    }

    if (force) {
        return {
            name: target.name,
            pathHashes,
            shouldRun: true,
            reason: "forced",
            changedPaths: [],
        };
    }

    const recorded = previous[target.name];
    if (!recorded) {
        return {
            name: target.name,
            pathHashes,
            shouldRun: true,
            reason: "never-passed",
            changedPaths: [],
        };
    }

    const changedPaths = watchedPaths.filter(watchedPath => recorded[watchedPath] !== pathHashes[watchedPath]);
    if (changedPaths.length > 0) {
        return {
            name: target.name,
            pathHashes,
            shouldRun: true,
            reason: "changed",
            changedPaths,
        };
    }

    return {
        name: target.name,
        pathHashes,
        shouldRun: false,
        reason: "unchanged",
        changedPaths: [],
    };
}
