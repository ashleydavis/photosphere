import { resetDevice, IResetDeviceOptions, IResetSettingsStore } from "../../lib/reset-device";
import type { IDatabaseEntry, ISharedSecretEntry } from "../../context/platform-context";

describe("resetDevice", () => {

    //
    // What each fake operation was asked to do, in the order it was asked, so the tests can check
    // both what was removed and that nothing was deleted before the database was closed.
    //
    let callLog: string[];

    //
    // An in-memory stand-in for the browser's local storage.
    //
    function makeSettingsStore(initial: Record<string, string>): IResetSettingsStore {
        const values = new Map<string, string>(Object.entries(initial));
        return {
            keys: () => Array.from(values.keys()),
            removeItem: (key: string) => {
                callLog.push(`remove-setting:${key}`);
                values.delete(key);
            },
        };
    }

    //
    // Builds the options with fakes that record what they were asked, over the given starting state.
    //
    function makeOptions(databases: IDatabaseEntry[], secrets: ISharedSecretEntry[], settings: Record<string, string>): IResetDeviceOptions {
        return {
            closeDatabase: async () => {
                callLog.push("close-database");
            },
            getDatabases: async () => databases,
            removeDatabaseEntry: async (name: string) => {
                callLog.push(`remove-database:${name}`);
            },
            listSecrets: async () => secrets,
            deleteSecret: async (name: string) => {
                callLog.push(`delete-secret:${name}`);
            },
            settingsStore: makeSettingsStore(settings),
            resetAppStorage: async () => {
                callLog.push("reset-app-storage");
                return {
                    entriesRemoved: 4,
                };
            },
        };
    }

    //
    // A database entry with only the fields the reset reads.
    //
    function makeDatabase(name: string): IDatabaseEntry {
        return {
            name,
            description: "",
            path: name,
        };
    }

    beforeEach(() => {
        callLog = [];
    });

    test("removes every database entry, every secret and every stored setting", async () => {
        const options = makeOptions(
            [makeDatabase("photos"), makeDatabase("archive")],
            [
                {
                    name: "s3-key",
                    type: "s3-credentials",
                },
            ],
            {
                "gallery-sort": "date",
                "photosphere.config.theme": "\"dark\"",
            }
        );

        const result = await resetDevice(options);

        expect(callLog).toEqual([
            "close-database",
            "remove-database:photos",
            "remove-database:archive",
            "delete-secret:s3-key",
            "remove-setting:gallery-sort",
            "remove-setting:photosphere.config.theme",
            "reset-app-storage",
        ]);
        expect(result).toEqual({
            databasesRemoved: 2,
            secretsRemoved: 1,
            settingsRemoved: 2,
            storageEntriesRemoved: 4,
        });
    });

    test("closes the open database before anything is deleted", async () => {
        const options = makeOptions([makeDatabase("photos")], [], {});

        await resetDevice(options);

        expect(callLog[0]).toBe("close-database");
    });

    test("empties the app's own storage last, once the entries and secrets have gone", async () => {
        const options = makeOptions(
            [makeDatabase("photos")],
            [
                {
                    name: "s3-key",
                    type: "s3-credentials",
                },
            ],
            { "gallery-sort": "date" }
        );

        await resetDevice(options);

        expect(callLog[callLog.length - 1]).toBe("reset-app-storage");
    });

    test("succeeds with nothing to remove", async () => {
        const options = makeOptions([], [], {});

        const result = await resetDevice(options);

        expect(result).toEqual({
            databasesRemoved: 0,
            secretsRemoved: 0,
            settingsRemoved: 0,
            storageEntriesRemoved: 4,
        });
        expect(callLog).toEqual([
            "close-database",
            "reset-app-storage",
        ]);
    });

    test("throws when a secret cannot be deleted, rather than reporting a reset that did not happen", async () => {
        const options = makeOptions(
            [],
            [
                {
                    name: "s3-key",
                    type: "s3-credentials",
                },
            ],
            {}
        );
        options.deleteSecret = async () => {
            throw new Error("the vault is locked");
        };

        await expect(resetDevice(options)).rejects.toThrow("the vault is locked");
        expect(callLog).not.toContain("reset-app-storage");
    });

    test("throws when the app's storage cannot be emptied", async () => {
        const options = makeOptions([], [], {});
        options.resetAppStorage = async () => {
            throw new Error("reset-app-storage failed");
        };

        await expect(resetDevice(options)).rejects.toThrow("reset-app-storage failed");
    });
});
