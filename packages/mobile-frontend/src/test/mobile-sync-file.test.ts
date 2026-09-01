import { SYNC_ENABLED_CONFIG_KEY, SYNC_ONLY_ON_WIFI_CONFIG_KEY } from "user-interface/src/lib/sync-config";
import { DEFAULT_SYNC_PAUSE_MS, DEFAULT_SYNC_SETTINGS, type ISyncFile } from "api/src/lib/sync-settings";
import {
    getSyncFileValue,
    isSyncFileKey,
    seedSyncSettingsFile,
    setSyncFileValue,
    type ISyncConfigFile,
    type ISyncFileContents,
} from "../lib/mobile-sync-file";

//
// Tests for the mobile syncing settings file.
//
// The real file lives in the app's storage sandbox and is reached through the embedded worker, which
// is why the functions take an ISyncConfigFile: the double below stands in for the worker, and the
// decisions (what a missing file reads as, what one key's write does to the other) are what is under
// test.
//
// This is the file the background sync loop reads while the app is off screen, so a write that loses
// a field is a phone that quietly stops pushing photos, or one that pushes them over cellular after
// being told not to.
//

//
// An in-memory settings file, standing in for the worker-backed one.
//
class FakeSyncConfigFile implements ISyncConfigFile {

    //
    // What the file currently holds, or undefined when there is no file.
    //
    contents: ISyncFile | undefined = undefined;

    //
    // How many times the file has been written, so a test can tell one write from two.
    //
    writeCount = 0;

    //
    // Reads the file, answering with the defaults when there is not one.
    //
    async read(): Promise<ISyncFileContents> {
        if (!this.contents) {
            return {
                settings: { ...DEFAULT_SYNC_SETTINGS },
                pauseBetweenRunsMs: DEFAULT_SYNC_PAUSE_MS,
                exists: false,
            };
        }
        return {
            settings: { ...this.contents.settings },
            pauseBetweenRunsMs: this.contents.pauseBetweenRunsMs,
            exists: true,
        };
    }

    //
    // Writes the file, replacing its contents.
    //
    async write(contents: ISyncFile): Promise<void> {
        this.writeCount += 1;
        this.contents = JSON.parse(JSON.stringify(contents));
    }
}

describe("mobile syncing settings file", () => {

    test("the two syncing keys belong to the file and other config keys do not", () => {
        expect(isSyncFileKey(SYNC_ENABLED_CONFIG_KEY)).toBe(true);
        expect(isSyncFileKey(SYNC_ONLY_ON_WIFI_CONFIG_KEY)).toBe(true);
        expect(isSyncFileKey("developerMode")).toBe(false);
        expect(isSyncFileKey("autoImportEnabled")).toBe(false);
    });

    test("a key that is not a syncing key is refused rather than silently ignored", async () => {
        const configFile = new FakeSyncConfigFile();

        await expect(getSyncFileValue(configFile, "developerMode")).rejects.toThrow();
        await expect(setSyncFileValue(configFile, "developerMode", true)).rejects.toThrow();
    });

    test("reading before the file exists gives no value rather than syncing off", async () => {
        // The settings card treats undefined as "nothing stored" and shows its own defaults, which
        // are syncing on. Handing it the reader's defaults instead would show a new user syncing
        // switched off, which is not what the app does.
        const configFile = new FakeSyncConfigFile();

        expect(await getSyncFileValue(configFile, SYNC_ENABLED_CONFIG_KEY)).toBeUndefined();
        expect(await getSyncFileValue(configFile, SYNC_ONLY_ON_WIFI_CONFIG_KEY)).toBeUndefined();
    });

    test("seeding writes the settings a fresh installation starts from", async () => {
        const configFile = new FakeSyncConfigFile();

        await seedSyncSettingsFile(configFile);

        expect(configFile.contents?.settings.enabled).toBe(true);
        expect(configFile.contents?.settings.onlyOnWifi).toBe(true);
        expect(configFile.contents?.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
    });

    test("seeding leaves an existing file alone", async () => {
        // Rewriting it would put syncing back on every time the app started, for somebody who had
        // switched it off.
        const configFile = new FakeSyncConfigFile();
        await setSyncFileValue(configFile, SYNC_ENABLED_CONFIG_KEY, false);
        const writesBefore = configFile.writeCount;

        await seedSyncSettingsFile(configFile);

        expect(configFile.writeCount).toBe(writesBefore);
        expect(configFile.contents?.settings.enabled).toBe(false);
    });

    test("writing one setting leaves the other as it was", async () => {
        const configFile = new FakeSyncConfigFile();
        await seedSyncSettingsFile(configFile);

        await setSyncFileValue(configFile, SYNC_ONLY_ON_WIFI_CONFIG_KEY, false);

        expect(await getSyncFileValue(configFile, SYNC_ENABLED_CONFIG_KEY)).toBe(true);
        expect(await getSyncFileValue(configFile, SYNC_ONLY_ON_WIFI_CONFIG_KEY)).toBe(false);
    });

    test("writing a setting before the file exists starts from the fresh-install settings", async () => {
        // Not from the reader's defaults: switching the Wi-Fi-only restriction off on a phone that
        // has never written the file must not switch syncing off as a side effect.
        const configFile = new FakeSyncConfigFile();

        await setSyncFileValue(configFile, SYNC_ONLY_ON_WIFI_CONFIG_KEY, false);

        expect(configFile.contents?.settings.enabled).toBe(true);
        expect(configFile.contents?.settings.onlyOnWifi).toBe(false);
    });

    test("two writes issued together do not lose each other's field", async () => {
        // The settings card can write both toggles back to back. Each write reads the whole file and
        // writes the whole file back, so without serialisation both read the same starting contents
        // and the second write clobbers the first one's field.
        const configFile = new FakeSyncConfigFile();
        await seedSyncSettingsFile(configFile);

        await Promise.all([
            setSyncFileValue(configFile, SYNC_ENABLED_CONFIG_KEY, false),
            setSyncFileValue(configFile, SYNC_ONLY_ON_WIFI_CONFIG_KEY, false),
        ]);

        expect(configFile.contents?.settings.enabled).toBe(false);
        expect(configFile.contents?.settings.onlyOnWifi).toBe(false);
    });

    test("a value that is not true is stored as false rather than as itself", async () => {
        const configFile = new FakeSyncConfigFile();
        await seedSyncSettingsFile(configFile);

        await setSyncFileValue(configFile, SYNC_ENABLED_CONFIG_KEY, undefined);

        expect(configFile.contents?.settings.enabled).toBe(false);
    });
});
