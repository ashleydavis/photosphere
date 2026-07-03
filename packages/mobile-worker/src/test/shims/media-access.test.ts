import { runMediaTool, getMediaHost, IMediaResult } from "../../shims/media-access";
import { makeHostErrorEnvelope } from "../../shims/host-access";

//
// Unit tests for runMediaTool: it marshals argv to JSON, decodes the result, and surfaces the
// native error convention as a thrown coded Error.
//
describe("runMediaTool", () => {

    test("JSON-encodes the argv and returns the parsed { exitCode, output }", () => {
        let receivedArgvJson = "";
        const hostFunction = (argvJson: string): string => {
            receivedArgvJson = argvJson;
            const result: IMediaResult = { exitCode: 0, output: "800 600" };
            return JSON.stringify(result);
        };

        const result = runMediaTool(hostFunction, ["/cache/a.jpg", "-format", "%w %h", "info:"]);

        expect(JSON.parse(receivedArgvJson)).toEqual(["/cache/a.jpg", "-format", "%w %h", "info:"]);
        expect(result).toEqual({ exitCode: 0, output: "800 600" });
    });

    test("returns a non-zero exit code without throwing", () => {
        const hostFunction = (): string => JSON.stringify({ exitCode: 1, output: "convert: no decode delegate" });

        const result = runMediaTool(hostFunction, ["/cache/missing.jpg", "info:"]);

        expect(result.exitCode).toBe(1);
        expect(result.output).toContain("no decode delegate");
    });

    test("throws a coded error when the host returns an error envelope", () => {
        const hostFunction = (): string => makeHostErrorEnvelope("EHOST", "imagemagick crashed");

        expect(() => runMediaTool(hostFunction, ["/cache/a.jpg", "info:"]))
            .toThrow(expect.objectContaining({ code: "EHOST", message: "imagemagick crashed" }));
    });
});

//
// Unit tests for getMediaHost: it returns the installed host lazily and fails clearly when absent.
//
describe("getMediaHost", () => {

    afterEach(() => {
        (globalThis as any).host = undefined;
    });

    test("returns the installed host", () => {
        const fakeHost = { imageMagick: () => "", ffmpeg: () => "", ffprobe: () => "" };
        (globalThis as any).host = fakeHost;
        expect(getMediaHost()).toBe(fakeHost);
    });

    test("throws a clear error when the host bridge is missing", () => {
        (globalThis as any).host = undefined;
        expect(() => getMediaHost()).toThrow(/host bridge .* is not installed/);
    });
});
