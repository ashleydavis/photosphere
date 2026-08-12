import { JsEngine } from "../lib/js-engine-plugin";
import { PluginDeviceMediaLibrary } from "../lib/device-media-library";

//
// The registered plugin is a plain stand-in object under test (see capacitor-core.mock.ts), so the
// methods the library reads through are installed on it here. That is what makes the marshalling
// testable without a device: what is asserted is exactly what crosses the bridge.
//
const plugin = JsEngine as any;

describe("PluginDeviceMediaLibrary", () => {

    beforeEach(() => {
        plugin.mediaLibraryList = jest.fn(async () => ({ json: JSON.stringify({ items: [] }) }));
        plugin.mediaLibraryExport = jest.fn(async () => ({ path: ".media-tmp/one.jpg" }));
        plugin.mediaLibraryRelease = jest.fn(async () => undefined);
        plugin.mediaLibraryDelete = jest.fn(async () => ({ json: JSON.stringify({ deletedIds: [], failedIds: [] }) }));
    });

    test("a page is parsed out of the JSON the native side returns", async () => {
        plugin.mediaLibraryList = jest.fn(async () => ({
            json: JSON.stringify({
                items: [{ id: "one", displayName: "one.jpg", mimeType: "image/jpeg", size: 12, createdAtMs: 5, albumId: "camera" }],
                nextCursor: "10",
            }),
        }));

        const page = await new PluginDeviceMediaLibrary().listPage(undefined, 50);

        expect(page.nextCursor).toBe("10");
        expect(page.items).toHaveLength(1);
        expect(page.items[0].id).toBe("one");
        expect(page.items[0].albumId).toBe("camera");
    });

    test("a missing cursor crosses the bridge as an empty string, which is what starts at the beginning", async () => {
        await new PluginDeviceMediaLibrary().listPage(undefined, 50);

        expect(plugin.mediaLibraryList).toHaveBeenCalledWith({ cursor: "", pageSize: 50 });
    });

    test("a cursor is passed through unchanged", async () => {
        await new PluginDeviceMediaLibrary().listPage("120", 25);

        expect(plugin.mediaLibraryList).toHaveBeenCalledWith({ cursor: "120", pageSize: 25 });
    });

    test("exporting returns the sandbox path the import reads from", async () => {
        const path = await new PluginDeviceMediaLibrary().exportItem("one");

        expect(path).toBe(".media-tmp/one.jpg");
        expect(plugin.mediaLibraryExport).toHaveBeenCalledWith({ itemId: "one" });
    });

    test("releasing names the item whose sandbox copy goes", async () => {
        await new PluginDeviceMediaLibrary().releaseItem("one");

        expect(plugin.mediaLibraryRelease).toHaveBeenCalledWith({ itemId: "one" });
    });

    test("a delete goes over as one JSON list, so the user sees one confirmation", async () => {
        await new PluginDeviceMediaLibrary().deleteItems(["one", "two"]);

        expect(plugin.mediaLibraryDelete).toHaveBeenCalledWith({ itemIdsJson: JSON.stringify(["one", "two"]) });
    });

    test("what the platform refused to delete comes back named", async () => {
        plugin.mediaLibraryDelete = jest.fn(async () => ({
            json: JSON.stringify({ deletedIds: ["one"], failedIds: ["two"] }),
        }));

        const result = await new PluginDeviceMediaLibrary().deleteItems(["one", "two"]);

        expect(result.deletedIds).toEqual(["one"]);
        expect(result.failedIds).toEqual(["two"]);
    });
});
