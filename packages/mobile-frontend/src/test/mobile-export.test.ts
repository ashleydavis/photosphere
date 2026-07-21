import {
    EXPORT_TEMP_DIR,
    sanitizePathSegment,
    buildExportFilePath,
    buildExportFolderPath,
    pickMobileFolder,
    saveMobileDownloadedFile,
    saveMobileDownloadedFiles,
    setInjectedExportOutcome,
    setInjectedPickFolderResult,
} from "../lib/mobile-export";
import type { IExportFileOptions, IExportFilesOptions, IJsEnginePlugin } from "../lib/js-engine-plugin";

//
// Builds a mock JsEngine plugin whose export methods return a configurable result and record their
// options, so tests can drive the export outcome without native code.
//
function makeMockPlugin() {
    const plugin: any = {
        exportFile: jest.fn().mockResolvedValue({ path: null }),
        exportFiles: jest.fn().mockResolvedValue({ paths: null }),
    };
    return plugin as IJsEnginePlugin & { exportFile: jest.Mock; exportFiles: jest.Mock };
}

describe("mobile export helpers", () => {
    //
    // A relative-path segment is reduced to its final component with separators and traversal removed.
    //
    test("sanitizePathSegment keeps the final component and rejects traversal", () => {
        expect(sanitizePathSegment("holiday.jpeg", "download")).toBe("holiday.jpeg");
        expect(sanitizePathSegment("a/b/c.png", "download")).toBe("c.png");
        expect(sanitizePathSegment("a\\b\\c.png", "download")).toBe("c.png");
        expect(sanitizePathSegment("..", "download")).toBe("download");
        expect(sanitizePathSegment("   ", "download")).toBe("download");
        expect(sanitizePathSegment("", "fallback")).toBe("fallback");
    });

    //
    // The single-file temp path is "<EXPORT_TEMP_DIR>/<uuid>/<filename>", keeping the real filename.
    //
    test("buildExportFilePath places the file under the temp dir with its name", () => {
        expect(buildExportFilePath("cat.jpeg", "uuid-1")).toBe(`${EXPORT_TEMP_DIR}/uuid-1/cat.jpeg`);
    });

    //
    // The batch temp folder is "<EXPORT_TEMP_DIR>/<uuid>".
    //
    test("buildExportFolderPath places the folder under the temp dir", () => {
        expect(buildExportFolderPath("uuid-2")).toBe(`${EXPORT_TEMP_DIR}/uuid-2`);
    });

    //
    // A staged pick-folder path is returned to the "Browse" caller without prompting.
    //
    test("pickMobileFolder returns the staged path for a Browse prompt", () => {
        setInjectedPickFolderResult("my-database");
        const folder = pickMobileFolder({ title: "Create Database" });
        expect(folder).toBe("my-database");
    });

    //
    // A staged null (cancel) makes pickMobileFolder resolve undefined, and injection is consumed once.
    //
    test("pickMobileFolder returns undefined when the staged prompt is cancelled, consuming the injection once", () => {
        setInjectedPickFolderResult(null);
        expect(pickMobileFolder({ title: "Create Database" })).toBeUndefined();

        // Injection is consumed once: the next call prompts instead. These tests run in the node
        // environment, which has no window, so stand one in carrying the prompt and confirm the
        // entered name is sanitised and returned.
        const globalWithWindow = globalThis as any;
        const originalWindow = globalWithWindow.window;
        globalWithWindow.window = { prompt: () => "  Second DB  " };
        try {
            expect(pickMobileFolder({ title: "Create Database" })).toBe("Second DB");
        }
        finally {
            globalWithWindow.window = originalWindow;
        }
    });

    //
    // The single-file save writes to a sandbox temp path carrying the filename, hands it out via the
    // sheet, and resolves true when the sheet completes.
    //
    test("saveMobileDownloadedFile writes to a sandbox temp path then hands it out, resolving true on success", async () => {
        const plugin = makeMockPlugin();
        let writtenPath: string | undefined;
        plugin.exportFile.mockImplementation(async (options: IExportFileOptions) => ({ path: options.path }));

        const delivered = await saveMobileDownloadedFile("photo.png", async (destinationPath) => {
            writtenPath = destinationPath;
            return true;
        }, plugin);

        expect(writtenPath!.startsWith(`${EXPORT_TEMP_DIR}/`)).toBe(true);
        expect(writtenPath!.endsWith("/photo.png")).toBe(true);
        expect(plugin.exportFile).toHaveBeenCalledWith({ path: writtenPath });
        expect(delivered).toBe(true);
    });

    //
    // A failed write resolves false and never presents the sheet.
    //
    test("saveMobileDownloadedFile resolves false and skips the sheet when the write fails", async () => {
        const plugin = makeMockPlugin();

        const delivered = await saveMobileDownloadedFile("photo.png", async () => false, plugin);

        expect(delivered).toBe(false);
        expect(plugin.exportFile).not.toHaveBeenCalled();
    });

    //
    // A cancelled sheet (native returns null) resolves false.
    //
    test("saveMobileDownloadedFile resolves false when the user cancels the sheet", async () => {
        const plugin = makeMockPlugin();
        plugin.exportFile.mockResolvedValue({ path: null });

        const delivered = await saveMobileDownloadedFile("photo.png", async () => true, plugin);

        expect(delivered).toBe(false);
    });

    //
    // A staged test outcome is forwarded to the plugin so it runs its completion handler (cleanup)
    // without presenting the sheet; the outcome is consumed once.
    //
    test("saveMobileDownloadedFile forwards a staged test outcome once", async () => {
        const plugin = makeMockPlugin();
        plugin.exportFile.mockResolvedValue({ path: null });
        setInjectedExportOutcome("cancelled");

        await saveMobileDownloadedFile("cat.jpeg", async () => true, plugin);
        const firstOptions = plugin.exportFile.mock.calls[0][0] as IExportFileOptions;
        expect(firstOptions.testOutcome).toBe("cancelled");

        await saveMobileDownloadedFile("dog.jpeg", async () => true, plugin);
        const secondOptions = plugin.exportFile.mock.calls[1][0] as IExportFileOptions;
        expect(secondOptions.testOutcome).toBeUndefined();
    });

    //
    // The batch save writes into a sandbox temp folder, hands the written files out, and resolves true.
    //
    test("saveMobileDownloadedFiles writes into a sandbox temp folder then hands the files out, resolving true", async () => {
        const plugin = makeMockPlugin();
        let writtenFolder: string | undefined;
        const deliverNames = ["a.jpeg", "b.png"];
        plugin.exportFiles.mockImplementation(async (options: IExportFilesOptions) => ({ paths: options.paths }));

        const delivered = await saveMobileDownloadedFiles(async (destinationFolder) => {
            writtenFolder = destinationFolder;
            return deliverNames.map(name => `${destinationFolder}/${name}`);
        }, plugin);

        expect(writtenFolder!.startsWith(`${EXPORT_TEMP_DIR}/`)).toBe(true);
        const expectedPaths = deliverNames.map(name => `${writtenFolder}/${name}`);
        expect(plugin.exportFiles).toHaveBeenCalledWith({ paths: expectedPaths });
        expect(delivered).toBe(true);
    });

    //
    // A failed batch write resolves false and never presents the sheet.
    //
    test("saveMobileDownloadedFiles resolves false and skips the sheet when the write fails", async () => {
        const plugin = makeMockPlugin();

        const delivered = await saveMobileDownloadedFiles(async () => undefined, plugin);

        expect(delivered).toBe(false);
        expect(plugin.exportFiles).not.toHaveBeenCalled();
    });

    //
    // When every file failed there is nothing to hand out: resolve true without presenting a sheet.
    //
    test("saveMobileDownloadedFiles resolves true without a sheet when there is nothing to hand out", async () => {
        const plugin = makeMockPlugin();

        const delivered = await saveMobileDownloadedFiles(async () => [], plugin);

        expect(delivered).toBe(true);
        expect(plugin.exportFiles).not.toHaveBeenCalled();
    });

    //
    // A cancelled batch sheet resolves false.
    //
    test("saveMobileDownloadedFiles resolves false when the user cancels the sheet", async () => {
        const plugin = makeMockPlugin();
        plugin.exportFiles.mockResolvedValue({ paths: null });

        const delivered = await saveMobileDownloadedFiles(async (destinationFolder) => [`${destinationFolder}/a.jpeg`], plugin);

        expect(delivered).toBe(false);
    });
});
