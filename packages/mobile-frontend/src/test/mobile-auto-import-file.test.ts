import { AUTO_IMPORT_ENABLED_KEY, AUTO_IMPORT_SOURCES_KEY, DEFAULT_DATABASE_PATH_KEY } from "user-interface/src/lib/auto-import-config";
import { DEFAULT_AUTO_IMPORT_PAUSE_MS } from "api/src/lib/auto-import-mobile";
import type { IAutoImportFile } from "api/src/lib/auto-import-mobile";
import {
    getAutoImportFileValue,
    isAutoImportFileKey,
    readAutoImportFile,
    setAutoImportFileValue,
    writeAutoImportFile,
    type IAutoImportConfigFile,
} from "../lib/mobile-auto-import-file";

//
// Tests for the mobile automatic import settings file.
//
// The real file lives in the app's storage sandbox and is reached through the embedded worker, which
// is why the functions take an IAutoImportConfigFile: the double below stands in for the worker, and
// the decisions (what a missing file reads as, what one key's write does to the others) are what is
// under test.
//
// This is the file the background import reads while the app is off screen, so a write that loses a
// field is a phone that quietly stops backing up, or backs up to the wrong database.
//

//
// An in-memory settings file, standing in for the worker-backed one.
//
class FakeAutoImportConfigFile implements IAutoImportConfigFile {

    //
    // What the file currently holds, or undefined when there is no file.
    //
    contents: IAutoImportFile | undefined = undefined;

    //
    // How many times the file has been written, so a test can tell one write from two.
    //
    writeCount = 0;

    //
    // Reads the file, answering with the defaults when there is not one.
    //
    async read(): Promise<IAutoImportFile> {
        if (!this.contents) {
            return {
                settings: {
                    enabled: false,
                    sources: [],
                },
                defaultDatabasePath: undefined,
                pauseBetweenRunsMs: DEFAULT_AUTO_IMPORT_PAUSE_MS,
            };
        }
        return JSON.parse(JSON.stringify(this.contents));
    }

    //
    // Writes the file, replacing its contents.
    //
    async write(contents: IAutoImportFile): Promise<void> {
        this.writeCount += 1;
        this.contents = JSON.parse(JSON.stringify(contents));
    }
}

describe("mobile automatic import settings file", () => {

    test("a file that has never been written reads as the defaults", async () => {
        const configFile = new FakeAutoImportConfigFile();

        const contents = await readAutoImportFile(configFile);

        expect(contents.settings.enabled).toBe(false);
        expect(contents.settings.sources).toEqual([]);
        expect(contents.defaultDatabasePath).toBeUndefined();
        expect(contents.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("a written file round-trips", async () => {
        const configFile = new FakeAutoImportConfigFile();

        await writeAutoImportFile(configFile, {
            settings: {
                enabled: true,
                sources: [{ type: "device-album", albumId: "all" }],
            },
            defaultDatabasePath: "photosphere-default",
            pauseBetweenRunsMs: 4000,
        });

        const contents = await readAutoImportFile(configFile);

        expect(contents.settings.enabled).toBe(true);
        expect(contents.settings.sources).toEqual([{ type: "device-album", albumId: "all" }]);
        expect(contents.defaultDatabasePath).toBe("photosphere-default");
        expect(contents.pauseBetweenRunsMs).toBe(4000);
    });

    test("a file holding nonsense reads as the defaults rather than throwing", async () => {
        // A settings file the user never sees must not be able to stop the app starting, so what is
        // unreadable is replaced by the default rather than raised.
        const configFile = new FakeAutoImportConfigFile();
        configFile.contents = {
            settings: {
                enabled: "yes please" as any,
                sources: [{ type: "nonsense" } as any],
            },
            defaultDatabasePath: undefined,
            pauseBetweenRunsMs: 0,
        };

        const contents = await readAutoImportFile(configFile);

        expect(contents.settings.enabled).toBe(false);
        expect(contents.settings.sources).toEqual([]);
        expect(contents.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("the automatic import keys are the ones the file owns", () => {
        expect(isAutoImportFileKey(AUTO_IMPORT_ENABLED_KEY)).toBe(true);
        expect(isAutoImportFileKey(AUTO_IMPORT_SOURCES_KEY)).toBe(true);
        expect(isAutoImportFileKey(DEFAULT_DATABASE_PATH_KEY)).toBe(true);
        expect(isAutoImportFileKey("developerMode")).toBe(false);
    });

    test("each key reads back what was written to it", async () => {
        const configFile = new FakeAutoImportConfigFile();

        await setAutoImportFileValue(configFile, AUTO_IMPORT_ENABLED_KEY, true);
        await setAutoImportFileValue(configFile, AUTO_IMPORT_SOURCES_KEY, [{ type: "device-album", albumId: "pets" }]);
        await setAutoImportFileValue(configFile, DEFAULT_DATABASE_PATH_KEY, "my-photos");

        expect(await getAutoImportFileValue(configFile, AUTO_IMPORT_ENABLED_KEY)).toBe(true);
        expect(await getAutoImportFileValue(configFile, AUTO_IMPORT_SOURCES_KEY)).toEqual([{ type: "device-album", albumId: "pets" }]);
        expect(await getAutoImportFileValue(configFile, DEFAULT_DATABASE_PATH_KEY)).toBe("my-photos");
    });

    test("writing one key leaves the others as they were", async () => {
        // The settings card writes the toggle and the watched places as separate calls, so a write
        // that carried only what its caller knew about would drop the rest.
        const configFile = new FakeAutoImportConfigFile();
        await setAutoImportFileValue(configFile, AUTO_IMPORT_SOURCES_KEY, [{ type: "device-album", albumId: "pets" }]);
        await setAutoImportFileValue(configFile, DEFAULT_DATABASE_PATH_KEY, "my-photos");

        await setAutoImportFileValue(configFile, AUTO_IMPORT_ENABLED_KEY, true);

        const contents = await readAutoImportFile(configFile);
        expect(contents.settings.enabled).toBe(true);
        expect(contents.settings.sources).toEqual([{ type: "device-album", albumId: "pets" }]);
        expect(contents.defaultDatabasePath).toBe("my-photos");
    });

    test("two writes issued at once do not overwrite each other's field", async () => {
        // Both writes read the whole file, change one field and write the whole file back, and the
        // read and the write are separate round-trips to the worker. Without serialising them, both
        // read the same starting contents and the second undoes the first.
        const configFile = new FakeAutoImportConfigFile();

        await Promise.all([
            setAutoImportFileValue(configFile, AUTO_IMPORT_ENABLED_KEY, true),
            setAutoImportFileValue(configFile, AUTO_IMPORT_SOURCES_KEY, [{ type: "device-album", albumId: "pets" }]),
        ]);

        const contents = await readAutoImportFile(configFile);
        expect(contents.settings.enabled).toBe(true);
        expect(contents.settings.sources).toEqual([{ type: "device-album", albumId: "pets" }]);
    });

    test("clearing the default database path leaves no database recorded", async () => {
        const configFile = new FakeAutoImportConfigFile();
        await setAutoImportFileValue(configFile, DEFAULT_DATABASE_PATH_KEY, "my-photos");

        await setAutoImportFileValue(configFile, DEFAULT_DATABASE_PATH_KEY, undefined);

        expect(await getAutoImportFileValue(configFile, DEFAULT_DATABASE_PATH_KEY)).toBeUndefined();
    });

    test("a key the file does not own is refused rather than silently written somewhere", async () => {
        const configFile = new FakeAutoImportConfigFile();

        await expect(setAutoImportFileValue(configFile, "developerMode", true))
            .rejects.toThrow("not an automatic import config key");
        await expect(getAutoImportFileValue(configFile, "developerMode"))
            .rejects.toThrow("not an automatic import config key");
        expect(configFile.writeCount).toBe(0);
    });
});
