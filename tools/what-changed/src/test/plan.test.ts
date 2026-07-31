import { TargetHashes } from "../lib/cache-store";
import { GateConfig } from "../lib/config";
import { buildTree, TreeNode } from "../lib/merkle";
import { planTarget, planTargets, watchedPathsFor } from "../lib/plan";

//
// A config with two targets watching separate directories, plus one shared always-watched file.
//
function makeConfig(): GateConfig {
    return {
        cacheDir: ".cache/what-changed",
        runnerCommand: ["./run.sh"],
        alwaysPaths: ["package.json"],
        ignoreExtensions: [],
        targets: [
            { name: "alpha", paths: ["dir-a"], platforms: [] },
            { name: "beta", paths: ["dir-b"], platforms: [] },
        ],
    };
}

//
// Builds a tree over the standard file set, letting one file's hash be overridden so a change can be
// simulated without touching a disk.
//
function makeTree(overrides: Map<string, string>): TreeNode {
    const fileHashes = new Map<string, string>([
        ["package.json", "pkg"],
        ["dir-a/one.txt", "a1"],
        ["dir-b/two.txt", "b1"],
    ]);
    for (const [filePath, hash] of overrides) {
        fileHashes.set(filePath, hash);
    }
    return buildTree(fileHashes);
}

//
// Records the hashes every target would see for an unchanged tree, as if both had just passed.
//
function recordAll(config: GateConfig, tree: TreeNode): TargetHashes {
    const recorded: TargetHashes = {};
    for (const plan of planTargets(config, tree, {}, "linux", [], true)) {
        recorded[plan.name] = plan.pathHashes;
    }
    return recorded;
}

test("watchedPathsFor merges the target paths with alwaysPaths, de-duplicates and sorts", () => {
    const config: GateConfig = {
        cacheDir: ".cache",
        runnerCommand: ["./run.sh"],
        alwaysPaths: ["package.json", "dir-a"],
        ignoreExtensions: [],
        targets: [],
    };

    const watched = watchedPathsFor(config, { name: "alpha", paths: ["dir-a", "scripts"], platforms: [] });

    expect(watched).toEqual(["dir-a", "package.json", "scripts"]);
});

test("planTargets returns shouldRun with reason never-passed when there is no recorded entry", () => {
    const config = makeConfig();
    const tree = makeTree(new Map());

    const plans = planTargets(config, tree, {}, "linux", [], false);

    expect(plans.map(plan => plan.reason)).toEqual(["never-passed", "never-passed"]);
    expect(plans.every(plan => plan.shouldRun)).toBe(true);
});

test("planTargets returns unchanged when every watched path matches the recorded hash", () => {
    const config = makeConfig();
    const tree = makeTree(new Map());
    const recorded = recordAll(config, tree);

    const plans = planTargets(config, tree, recorded, "linux", [], false);

    expect(plans.map(plan => plan.reason)).toEqual(["unchanged", "unchanged"]);
    expect(plans.every(plan => plan.shouldRun)).toBe(false);
});

test("planTargets returns changed and names only the paths that differ", () => {
    const config = makeConfig();
    const recorded = recordAll(config, makeTree(new Map()));
    const changedTree = makeTree(new Map([["dir-a/one.txt", "edited"]]));

    const plans = planTargets(config, changedTree, recorded, "linux", [], false);

    const alpha = plans.find(plan => plan.name === "alpha")!;
    const beta = plans.find(plan => plan.name === "beta")!;
    expect(alpha.shouldRun).toBe(true);
    expect(alpha.reason).toBe("changed");
    expect(alpha.changedPaths).toEqual(["dir-a"]);
    expect(beta.shouldRun).toBe(false);
});

test("planTargets treats a watched path missing from the recorded entry as changed", () => {
    const config = makeConfig();
    const tree = makeTree(new Map());
    const recorded = recordAll(config, tree);
    delete recorded["alpha"]["package.json"];

    const plans = planTargets(config, tree, recorded, "linux", [], false);

    const alpha = plans.find(plan => plan.name === "alpha")!;
    expect(alpha.shouldRun).toBe(true);
    expect(alpha.changedPaths).toEqual(["package.json"]);
});

test("planTargets returns reason forced for every target when force is true", () => {
    const config = makeConfig();
    const tree = makeTree(new Map());
    const recorded = recordAll(config, tree);

    const plans = planTargets(config, tree, recorded, "linux", [], true);

    expect(plans.map(plan => plan.reason)).toEqual(["forced", "forced"]);
    expect(plans.every(plan => plan.shouldRun)).toBe(true);
});

test("planTargets never runs a target whose platforms exclude the host, even changed and forced", () => {
    const config = makeConfig();
    config.targets[0].platforms = ["darwin"];
    const recorded = recordAll(config, makeTree(new Map()));
    const changedTree = makeTree(new Map([["dir-a/one.txt", "edited"]]));

    const notForced = planTargets(config, changedTree, recorded, "linux", [], false);
    const forced = planTargets(config, changedTree, recorded, "linux", [], true);

    const alphaNotForced = notForced.find(plan => plan.name === "alpha")!;
    const alphaForced = forced.find(plan => plan.name === "alpha")!;
    expect(alphaNotForced.shouldRun).toBe(false);
    expect(alphaNotForced.reason).toBe("wrong-platform");
    expect(alphaForced.shouldRun).toBe(false);
    expect(alphaForced.reason).toBe("wrong-platform");
});

test("planTargets considers only the named targets when requestedNames is non-empty", () => {
    const config = makeConfig();
    const tree = makeTree(new Map());

    const plans = planTargets(config, tree, {}, "linux", ["beta"], false);

    expect(plans.map(plan => plan.name)).toEqual(["beta"]);
});

test("planTargets marks every target as changed when a path in alwaysPaths changed", () => {
    const config = makeConfig();
    const recorded = recordAll(config, makeTree(new Map()));
    const changedTree = makeTree(new Map([["package.json", "edited"]]));

    const plans = planTargets(config, changedTree, recorded, "linux", [], false);

    expect(plans.map(plan => plan.reason)).toEqual(["changed", "changed"]);
    expect(plans.every(plan => plan.changedPaths.includes("package.json"))).toBe(true);
});

test("planTargets returns an empty list when requestedNames names nothing in the config", () => {
    const config = makeConfig();
    const tree = makeTree(new Map());

    expect(planTargets(config, tree, {}, "linux", ["nosuchtarget"], false)).toEqual([]);
});

test("planTarget returns never-passed with no changed paths for an unrecorded target", () => {
    const config = makeConfig();
    const tree = makeTree(new Map());

    const plan = planTarget(config, tree, {}, "linux", config.targets[0], false);

    expect(plan.name).toBe("alpha");
    expect(plan.shouldRun).toBe(true);
    expect(plan.reason).toBe("never-passed");
    expect(plan.changedPaths).toEqual([]);
    expect(Object.keys(plan.pathHashes).sort()).toEqual(["dir-a", "package.json"]);
});

test("planTarget checks the platform before force, so a wrong platform wins", () => {
    const config = makeConfig();
    const tree = makeTree(new Map());
    const darwinOnly = { name: "alpha", paths: ["dir-a"], platforms: ["darwin"] };

    const plan = planTarget(config, tree, {}, "linux", darwinOnly, true);

    expect(plan.shouldRun).toBe(false);
    expect(plan.reason).toBe("wrong-platform");
});

test("planTarget runs a target whose platforms include the host", () => {
    const config = makeConfig();
    const tree = makeTree(new Map());
    const linuxOnly = { name: "alpha", paths: ["dir-a"], platforms: ["linux", "darwin"] };

    const plan = planTarget(config, tree, {}, "linux", linuxOnly, false);

    expect(plan.shouldRun).toBe(true);
    expect(plan.reason).toBe("never-passed");
});

test("planTarget lists every differing watched path, in sorted order", () => {
    const config = makeConfig();
    const tree = makeTree(new Map([["dir-a/one.txt", "edited"], ["package.json", "edited"]]));
    const recorded = recordAll(config, makeTree(new Map()));

    const plan = planTarget(config, tree, recorded, "linux", config.targets[0], false);

    expect(plan.reason).toBe("changed");
    expect(plan.changedPaths).toEqual(["dir-a", "package.json"]);
});

test("planTarget treats a watched path that does not exist as a stable missing marker", () => {
    //
    // A target can watch a directory that is not there yet. It has to hash to something stable, so
    // that creating the first file under it registers as a change rather than being invisible.
    //
    const config = makeConfig();
    const absentTarget = { name: "gamma", paths: ["dir-absent"], platforms: [] };
    const tree = makeTree(new Map());

    const before = planTarget(config, tree, {}, "linux", absentTarget, false);
    const recorded = { gamma: before.pathHashes };
    const unchanged = planTarget(config, tree, recorded, "linux", absentTarget, false);
    const created = planTarget(config, makeTree(new Map([["dir-absent/new.txt", "n1"]])), recorded, "linux", absentTarget, false);

    expect(unchanged.reason).toBe("unchanged");
    expect(created.reason).toBe("changed");
    expect(created.changedPaths).toEqual(["dir-absent"]);
});

test("planTargets still computes pathHashes on the skip paths", () => {
    const config = makeConfig();
    config.targets[1].platforms = ["darwin"];
    const tree = makeTree(new Map());
    const recorded = recordAll(config, tree);

    const plans = planTargets(config, tree, recorded, "linux", [], false);

    const alpha = plans.find(plan => plan.name === "alpha")!;
    const beta = plans.find(plan => plan.name === "beta")!;
    expect(alpha.reason).toBe("unchanged");
    expect(Object.keys(alpha.pathHashes).sort()).toEqual(["dir-a", "package.json"]);
    expect(beta.reason).toBe("wrong-platform");
    expect(Object.keys(beta.pathHashes).sort()).toEqual(["dir-b", "package.json"]);
});
