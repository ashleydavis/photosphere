//
// Typed access to the native device photo library host functions.
//
// Automatic import reads the device photo library through these on mobile, the same way it reads
// folders through the filesystem on desktop. Each host function takes and returns JSON strings,
// because that is all the engine bridge carries; an error comes back as the `@@HOSTERR@@` envelope
// and is decoded into a coded Error by `callHost` rather than being thrown across the bridge.
//
// The host is read lazily at call time, mirroring the fs and media-tool shims, so the runtime-wrapped
// host is always the one used.
//

import { callHost } from "./host-access";

//
// One item in the device photo library, as the native side describes it.
//
export interface IMediaLibraryItem {
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
export interface IMediaLibraryPage {
    // The items in this page.
    items: IMediaLibraryItem[];

    // Where the next page starts, absent at the end of the library.
    nextCursor?: string;
}

//
// One album in the device photo library.
//
export interface IMediaLibraryAlbum {
    // The platform's own identifier for the album.
    id: string;

    // The album's name, as the user sees it.
    name: string;

    // How many items the album holds.
    itemCount: number;
}

//
// What the native side reports after being asked to delete items.
//
export interface IMediaLibraryDeleteResult {
    // The items that were deleted.
    deletedIds: string[];

    // The items that were not, because the user declined the system confirmation or the platform
    // refused. Never empty and silent: a caller that believes a photo is gone when it is not would
    // go on to free space that is still in use.
    failedIds: string[];
}

//
// The native host functions the device photo library needs.
//
// Every one of these is implemented natively on Android and iOS. A platform that has not implemented
// one throws NOT IMPLEMENTED naming itself, rather than returning something that looks like an empty
// library, because an empty library is indistinguishable from "the user has no photos" and would
// silently back up nothing.
//
export interface IMediaLibraryHost {
    // Returns one page of the library as JSON, given an optional cursor and a page size.
    mediaLibraryList: (cursor: string, pageSize: number) => string;

    // Copies one item into the sandbox and returns the sandbox-relative path it was written to.
    mediaLibraryOpen: (itemId: string) => string;

    // Deletes the sandbox copy an open made.
    mediaLibraryClose: (itemId: string) => void;

    // Returns the albums in the library as JSON.
    mediaLibraryAlbums: () => string;

    // Asks to delete the named items, as one system confirmation, and returns the outcome as JSON.
    mediaLibraryDelete: (itemIdsJson: string) => string;
}

//
// Returns the installed native host bridge, throwing a clear error when it is missing, which would
// mean the photo library was reached for outside the embedded worker.
//
export function getMediaLibraryHost(): IMediaLibraryHost {
    const host = (globalThis as any).host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; the device photo library cannot be read.");
    }

    return host as IMediaLibraryHost;
}

//
// Returns one page of the device photo library.
//
export function listMediaLibraryPage(cursor: string | undefined, pageSize: number): IMediaLibraryPage {
    const host = getMediaLibraryHost();
    const resultJson = callHost(() => host.mediaLibraryList(cursor ?? "", pageSize));
    return JSON.parse(resultJson) as IMediaLibraryPage;
}

//
// Copies one library item into the sandbox and returns the path the import can read it from.
//
export function openMediaLibraryItem(itemId: string): string {
    const host = getMediaLibraryHost();
    return callHost(() => host.mediaLibraryOpen(itemId));
}

//
// Deletes the sandbox copy an open made.
//
export function closeMediaLibraryItem(itemId: string): void {
    const host = getMediaLibraryHost();
    callHost(() => host.mediaLibraryClose(itemId));
}

//
// Returns the albums in the device photo library.
//
export function listMediaLibraryAlbums(): IMediaLibraryAlbum[] {
    const host = getMediaLibraryHost();
    const resultJson = callHost(() => host.mediaLibraryAlbums());
    return JSON.parse(resultJson) as IMediaLibraryAlbum[];
}

//
// Asks the platform to delete the named items, as one system confirmation.
//
export function deleteMediaLibraryItems(itemIds: string[]): IMediaLibraryDeleteResult {
    const host = getMediaLibraryHost();
    const resultJson = callHost(() => host.mediaLibraryDelete(JSON.stringify(itemIds)));
    return JSON.parse(resultJson) as IMediaLibraryDeleteResult;
}
