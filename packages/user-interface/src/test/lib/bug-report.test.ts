import { createGitHubIssueUrl, generateBugReportTemplate, openBugReport } from "../../lib/bug-report";
import { log, setLog } from "utils";
import type { ILog, ILogDetails } from "utils";

describe("generateBugReportTemplate", () => {

    test("includes the user agent", () => {
        const template = generateBugReportTemplate("test-user-agent", { logFilePath: null, logHeader: "the header" });
        expect(template).toContain("- User Agent: test-user-agent");
    });

    test("includes the log header and log file path", () => {
        const template = generateBugReportTemplate("test-user-agent", { logFilePath: "/logs/photosphere.log", logHeader: "the header" });
        expect(template).toContain("the header");
        expect(template).toContain("`/logs/photosphere.log`");
    });

    test("shows a placeholder when there is no log file", () => {
        const template = generateBugReportTemplate("test-user-agent", { logFilePath: null, logHeader: "No log file available" });
        expect(template).toContain("`No log file available`");
    });

    test("includes the expected sections", () => {
        const template = generateBugReportTemplate("test-user-agent", { logFilePath: null, logHeader: "the header" });
        expect(template).toContain("## Bug Description");
        expect(template).toContain("## Steps to Reproduce");
        expect(template).toContain("## Expected Behavior");
        expect(template).toContain("## Actual Behavior");
        expect(template).toContain("## System Information");
        expect(template).toContain("## Log Header");
        expect(template).toContain("## Log File");
        expect(template).toContain("## Additional Context");
    });
});

describe("createGitHubIssueUrl", () => {

    test("targets the photosphere new issue page", () => {
        const url = createGitHubIssueUrl("Bug Report", "body text");
        expect(url.startsWith("https://github.com/ashleydavis/photosphere/issues/new?")).toBe(true);
    });

    test("encodes the title, body, and bug label", () => {
        const url = createGitHubIssueUrl("My Title", "My body & details");
        const params = new URLSearchParams(url.split("?")[1]);
        expect(params.get("title")).toBe("My Title");
        expect(params.get("body")).toBe("My body & details");
        expect(params.get("labels")).toBe("bug");
    });
});

describe("openBugReport", () => {

    //
    // Creates a fake log that returns the given log details.
    //
    function makeFakeLog(logDetails: ILogDetails): ILog {
        return {
            info: () => {},
            verbose: () => {},
            error: () => {},
            exception: () => {},
            warn: () => {},
            debug: () => {},
            tool: () => {},
            event: () => {},
            verboseEnabled: false,
            getLogDetails: () => Promise.resolve(logDetails),
        };
    }

    test("opens the pre-filled issue url in a new window", async () => {
        const originalLog = log;
        const windowOpen = jest.fn();
        (globalThis as any).navigator = { userAgent: "test-user-agent" };
        (globalThis as any).window = { open: windowOpen };
        setLog(makeFakeLog({ logFilePath: "/logs/photosphere.log", logHeader: "the log header" }));

        try {
            await openBugReport();
        }
        finally {
            setLog(originalLog);
            delete (globalThis as any).navigator;
            delete (globalThis as any).window;
        }

        expect(windowOpen).toHaveBeenCalledTimes(1);
        const [url, target] = windowOpen.mock.calls[0];
        expect(url.startsWith("https://github.com/ashleydavis/photosphere/issues/new?")).toBe(true);
        const params = new URLSearchParams(url.split("?")[1]);
        const body = params.get("body");
        expect(body).toContain("test-user-agent");
        expect(body).toContain("the log header");
        expect(body).toContain("/logs/photosphere.log");
        expect(target).toBe("_blank");
    });
});
