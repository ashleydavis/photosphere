import { mkdtemp, rm, writeFile } from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { PassedFileHashes } from "../lib/cache-store";
import { describeChangedPaths, filterIgnoredBaseline, reportChangedFiles, reportPlans, runGate } from "../lib/gate";
import { TargetPlan } from "../lib/plan";

//
// A throwaway directory for the config-handling tests. It is deliberately NOT a git repository:
// nothing in this suite creates, stages or commits anything, in any repository.
//
let workDir: string;

//
// Everything the gate printed during the test, captured from console.log.
//
let printedLines: string[];

//
// The real console.log, restored after each test.
//
const originalConsoleLog = console.log;

//
// Writes a minimal valid config into the throwaway directory and returns its path.
//
async function writeConfig(): Promise<string> {
    const configPath = path.join(workDir, "what-changed.json");
    await writeFile(configPath, JSON.stringify({
        runnerCommand: ["/bin/true"],
        targets: [{ name: "alpha", paths: ["dir-a"] }],
    }));
    return configPath;
}

beforeEach(async () => {
    workDir = await mkdtemp(path.join(os.tmpdir(), "what-changed-gate-"));
    printedLines = [];
    console.log = (line?: any) => {
        printedLines.push(String(line === undefined ? "" : line));
    };
});

afterEach(async () => {
    console.log = originalConsoleLog;
    await rm(workDir, { recursive: true, force: true });
});

test("runGate prints the help text and returns 0 for --help", async () => {
    const exitCode = await runGate(["--help"], workDir, "linux");

    expect(exitCode).toBe(0);
    expect(printedLines.join("\n")).toContain("--force");
    expect(printedLines.join("\n")).toContain("--baseline");
});

test("runGate throws naming the path when the config file is missing", async () => {
    await expect(runGate([], workDir, "linux")).rejects.toThrow(/what-changed\.json/);
});

test("runGate throws naming the offending target when a requested name is unknown", async () => {
    await writeConfig();

    await expect(runGate(["nosuchtarget"], workDir, "linux")).rejects.toThrow(/"nosuchtarget" is not a target/);
});

test("runGate throws on an unknown option before reading anything", async () => {
    await expect(runGate(["--nosuchoption"], workDir, "linux")).rejects.toThrow(/Unknown option "--nosuchoption"/);
});

test("runGate throws when the config is not valid JSON", async () => {
    await writeFile(path.join(workDir, "what-changed.json"), "{ not json");

    await expect(runGate([], workDir, "linux")).rejects.toThrow(/not valid JSON/);
});

test("reportChangedFiles says so for an empty baseline", () => {
    reportChangedFiles(new Map([["a.txt", "h1"]]), {});

    expect(printedLines.join("\n")).toContain("No passing run recorded yet");
});

test("reportChangedFiles prints a line per change and a summary", () => {
    reportChangedFiles(new Map([["a.txt", "edited"]]), { "a.txt": "h1" });

    expect(printedLines[0]).toBe("Changed since the last passing run:");
    expect(printedLines[1]).toBe("  M  edited  a.txt");
    expect(printedLines[3]).toBe("1 changed, 1 file(s) checked.");
});

test("reportChangedFiles says so when nothing differs from the baseline", () => {
    reportChangedFiles(new Map([["a.txt", "h1"]]), { "a.txt": "h1" });

    expect(printedLines.join("\n")).toContain("No files have changed since the last passing run");
});

test("filterIgnoredBaseline drops the ignored extensions from a recorded baseline", () => {
    //
    // Without this, adding an extension to ignoreExtensions would report every already-recorded file
    // of that type as a deletion on the very next run.
    //
    const baseline: PassedFileHashes = { "a.ts": "h1", "readme.md": "h2" };

    expect(filterIgnoredBaseline(baseline, [".md"])).toEqual({ "a.ts": "h1" });
});

test("filterIgnoredBaseline returns the baseline untouched when nothing is ignored", () => {
    const baseline: PassedFileHashes = { "a.ts": "h1", "readme.md": "h2" };

    expect(filterIgnoredBaseline(baseline, [])).toBe(baseline);
});

test("reportPlans prints one line per target, marking run and skip", () => {
    const plans: TargetPlan[] = [
        { name: "alpha", pathHashes: {}, shouldRun: true, reason: "changed", changedPaths: ["dir-a"] },
        { name: "beta", pathHashes: {}, shouldRun: false, reason: "unchanged", changedPaths: [] },
    ];

    reportPlans(plans);

    expect(printedLines[0]).toBe("What changed:");
    expect(printedLines[1]).toBe("  RUN   alpha  (changed): dir-a");
    expect(printedLines[2]).toBe("  SKIP  beta  (unchanged)");
});

test("reportPlans says so when no target matched", () => {
    reportPlans([]);

    expect(printedLines).toEqual(["No targets matched."]);
});

test("describeChangedPaths returns an empty string when nothing changed", () => {
    const plan: TargetPlan = { name: "alpha", pathHashes: {}, shouldRun: false, reason: "unchanged", changedPaths: [] };

    expect(describeChangedPaths(plan)).toBe("");
});

test("describeChangedPaths joins the changed paths with a comma", () => {
    const plan: TargetPlan = { name: "alpha", pathHashes: {}, shouldRun: true, reason: "changed", changedPaths: ["dir-a", "package.json"] };

    expect(describeChangedPaths(plan)).toBe(": dir-a, package.json");
});
