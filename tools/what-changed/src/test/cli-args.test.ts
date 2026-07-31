import { helpText, parseCliArgs } from "../lib/cli-args";

test("parseCliArgs returns the defaults for an empty argument list", () => {
    const options = parseCliArgs([]);

    expect(options.configPath).toBe("what-changed.json");
    expect(options.force).toBe(false);
    expect(options.planOnly).toBe(false);
    expect(options.baselineOnly).toBe(false);
    expect(options.showHelp).toBe(false);
    expect(options.targetNames).toEqual([]);
});

test("parseCliArgs sets force for --force and planOnly for --plan", () => {
    expect(parseCliArgs(["--force"]).force).toBe(true);
    expect(parseCliArgs(["--plan"]).planOnly).toBe(true);
    expect(parseCliArgs(["--files"]).filesOnly).toBe(true);
    expect(parseCliArgs(["--baseline"]).baselineOnly).toBe(true);
    expect(parseCliArgs(["--help"]).showHelp).toBe(true);
});

test("parseCliArgs reads the value of --config", () => {
    const options = parseCliArgs(["--config", "other/gate.json"]);

    expect(options.configPath).toBe("other/gate.json");
});

test("parseCliArgs collects positional target names, in order and alongside flags", () => {
    const options = parseCliArgs(["compile", "--force", "test", "--config", "gate.json", "test:cli"]);

    expect(options.targetNames).toEqual(["compile", "test", "test:cli"]);
    expect(options.force).toBe(true);
    expect(options.configPath).toBe("gate.json");
});

test("parseCliArgs ignores a bare -- wherever it appears", () => {
    const options = parseCliArgs(["compile", "--", "--plan"]);

    expect(options.targetNames).toEqual(["compile"]);
    expect(options.planOnly).toBe(true);
});

test("parseCliArgs throws on an unknown flag, naming it", () => {
    expect(() => parseCliArgs(["--nope"])).toThrow(/Unknown option "--nope"/);
});

test("parseCliArgs throws when --config has no value", () => {
    expect(() => parseCliArgs(["--config"])).toThrow(/"--config" option needs a path/);
    expect(() => parseCliArgs(["--config", "--force"])).toThrow(/"--config" option needs a path/);
});

test("helpText mentions every option", () => {
    const text = helpText();

    expect(text).toContain("--force");
    expect(text).toContain("--plan");
    expect(text).toContain("--files");
    expect(text).toContain("--baseline");
    expect(text).toContain("--config");
});
