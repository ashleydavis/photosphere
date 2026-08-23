import {
    DEFAULT_AUTO_IMPORT_SETTINGS,
    IAutoImportSettings,
    normaliseAutoImportSettings,
    normaliseAutoImportSource,
} from "api";

describe("auto-import-settings", () => {

    test("returns the defaults when there is nothing stored", () => {
        expect(normaliseAutoImportSettings(undefined)).toEqual(DEFAULT_AUTO_IMPORT_SETTINGS);
        expect(normaliseAutoImportSettings(null)).toEqual(DEFAULT_AUTO_IMPORT_SETTINGS);
    });

    test("does not hand out the shared defaults object", () => {
        const settings = normaliseAutoImportSettings(undefined);
        settings.sources.push({ type: "device-album", albumId: "camera" });
        expect(DEFAULT_AUTO_IMPORT_SETTINGS.sources).toEqual([]);
    });

    test("leaves valid settings untouched", () => {
        const stored: IAutoImportSettings = {
            enabled: true,
            sources: [
                { type: "folder", path: "/home/someone/Pictures", recurse: false },
                { type: "device-album", albumId: "camera-roll" },
            ],
            backfillItemsPerMinute: 120,
        };

        expect(normaliseAutoImportSettings(stored)).toEqual(stored);
    });

    test("fills missing fields from the defaults", () => {
        const normalised = normaliseAutoImportSettings({ enabled: true });

        expect(normalised).toEqual({
            enabled: true,
            sources: [],
            backfillItemsPerMinute: DEFAULT_AUTO_IMPORT_SETTINGS.backfillItemsPerMinute,
        });
    });

    test("replaces booleans that are not booleans", () => {
        const stored = { enabled: "yes" } as any;
        const normalised = normaliseAutoImportSettings(stored);

        expect(normalised.enabled).toBe(false);
    });

    test("replaces pacing numbers that cannot be used", () => {
        for (const badValue of [0, -30, Number.NaN, Number.POSITIVE_INFINITY, "60"]) {
            const stored = {
                backfillItemsPerMinute: badValue,
            } as any;
            const normalised = normaliseAutoImportSettings(stored);

            expect(normalised.backfillItemsPerMinute).toBe(DEFAULT_AUTO_IMPORT_SETTINGS.backfillItemsPerMinute);
        }
    });

    test("drops malformed sources and keeps the good ones", () => {
        const stored = {
            sources: [
                { type: "folder", path: "/photos", recurse: true },
                { type: "folder" },
                { type: "folder", path: "" },
                { type: "device-album", albumId: "camera" },
                { type: "device-album" },
                { type: "carrier-pigeon", path: "/photos" },
                null,
                undefined,
            ],
        } as any;

        expect(normaliseAutoImportSettings(stored).sources).toEqual([
            { type: "folder", path: "/photos", recurse: true },
            { type: "device-album", albumId: "camera" },
        ]);
    });

    test("drops a sources field that is not a list", () => {
        const stored = { sources: "/photos" } as any;
        expect(normaliseAutoImportSettings(stored).sources).toEqual([]);
    });

    test("a folder source with no recurse flag recurses", () => {
        expect(normaliseAutoImportSource({ type: "folder", path: "/photos" }))
            .toEqual({ type: "folder", path: "/photos", recurse: true });
    });

    test("a folder source keeps an explicit recurse flag", () => {
        expect(normaliseAutoImportSource({ type: "folder", path: "/photos", recurse: false }))
            .toEqual({ type: "folder", path: "/photos", recurse: false });
    });

    test("an unrecognised source type is dropped", () => {
        expect(normaliseAutoImportSource({ type: "album", albumId: "camera" })).toBeUndefined();
        expect(normaliseAutoImportSource(undefined)).toBeUndefined();
        expect(normaliseAutoImportSource(null)).toBeUndefined();
    });
});
