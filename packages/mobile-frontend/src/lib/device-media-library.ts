import { JsEngine } from "./js-engine-plugin";

//
// The device photo library, as the frontend reads it.
//
// Automatic import on mobile is driven from the WebView rather than from a worker task, so the
// library is reached through the Capacitor plugin rather than through the embedded engine's host
// bridge. The reason is the engine pool: it has three slots, the asset server holds one for the life
// of the app, and a long-running import loop in a second slot leaves nothing for the tasks the
// import it queues needs in turn, so the import waits for a slot that can never come free.
//
// The reading is behind an interface so the loop above it can be tested without a device.
//

//
// One item in the device photo library, as the native side describes it.
//
export interface IDeviceMediaLibraryItem {
    // The platform's own identifier for the item.
    id: string;

    // What to show the user while this item is being imported.
    displayName: string;

    // The item's MIME type.
    mimeType: string;

    // The item's size in bytes.
    size: number;

    // When the item was created, in milliseconds since the epoch.
    createdAtMs: number;

    // The album the item belongs to, or an empty string when it claims none.
    albumId: string;
}

//
// One page of the device photo library.
//
export interface IDeviceMediaLibraryPage {
    // The items in this page.
    items: IDeviceMediaLibraryItem[];

    // Where the next page starts, absent at the end of the library.
    nextCursor?: string;
}

//
// What the native side reports after being asked to delete items.
//
export interface IDeviceMediaLibraryDeleteResult {
    // The items that were deleted.
    deletedIds: string[];

    // The items that were not, because the user declined the system confirmation or the platform
    // refused. Never empty and silent: a caller that believes a photo is gone when it is not would
    // go on to free space that is still in use.
    failedIds: string[];
}

//
// Everything automatic import needs from the device photo library.
//
export interface IDeviceMediaLibrary {
    //
    // Returns one page of the library. Pass undefined as the cursor to start at the beginning.
    //
    listPage(cursor: string | undefined, pageSize: number): Promise<IDeviceMediaLibraryPage>;

    //
    // Copies one item into the sandbox and returns the sandbox-relative path it was written to.
    //
    exportItem(itemId: string): Promise<string>;

    //
    // Deletes the sandbox copy an export made. The library item itself is untouched.
    //
    releaseItem(itemId: string): Promise<void>;

    //
    // Asks to delete the named items from the library, as one system confirmation.
    //
    deleteItems(itemIds: string[]): Promise<IDeviceMediaLibraryDeleteResult>;
}

//
// The device photo library, read through the native Capacitor plugin.
//
export class PluginDeviceMediaLibrary implements IDeviceMediaLibrary {
    //
    // Returns one page of the library.
    //
    async listPage(cursor: string | undefined, pageSize: number): Promise<IDeviceMediaLibraryPage> {
        const result = await JsEngine.mediaLibraryList({ cursor: cursor ?? "", pageSize });
        return JSON.parse(result.json) as IDeviceMediaLibraryPage;
    }

    //
    // Copies one item into the sandbox.
    //
    async exportItem(itemId: string): Promise<string> {
        const result = await JsEngine.mediaLibraryExport({ itemId });
        return result.path;
    }

    //
    // Deletes the sandbox copy an export made.
    //
    async releaseItem(itemId: string): Promise<void> {
        await JsEngine.mediaLibraryRelease({ itemId });
    }

    //
    // Asks to delete the named items from the library.
    //
    async deleteItems(itemIds: string[]): Promise<IDeviceMediaLibraryDeleteResult> {
        const result = await JsEngine.mediaLibraryDelete({ itemIdsJson: JSON.stringify(itemIds) });
        return JSON.parse(result.json) as IDeviceMediaLibraryDeleteResult;
    }
}
