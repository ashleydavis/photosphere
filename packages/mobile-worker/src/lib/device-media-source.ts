import { ALL_DEVICE_MEDIA_ALBUM_ID, IDeviceAlbumAutoImportSource } from "api/src/lib/auto-import-settings";
import {
    IMediaItem,
    IMediaSource,
    IMediaSourceListPage,
    MediaSourceDeleteError,
} from "api/src/lib/media-source";
import {
    closeMediaLibraryItem,
    deleteMediaLibraryItems,
    listMediaLibraryPage,
    openMediaLibraryItem,
    IMediaLibraryItem,
} from "../shims/media-library";

//
// The device photo library, presented as a media source.
//
// This is what lets the automatic import task run unchanged on a phone: the task only ever talks to
// IMediaSource, and this is the mobile implementation of it, exactly as FolderMediaSource is the
// desktop one.
//

//
// A media source over the device photo library.
//
export class DeviceMediaSource implements IMediaSource {
    // The albums to take items from. An empty list means the whole library.
    private readonly albumIds: string[];

    constructor(sources: IDeviceAlbumAutoImportSource[]) {
        // The reserved "everything" id is not an album to filter by: a source list that includes it
        // covers the whole library, which is what a user gets before they choose albums.
        const watchesWholeLibrary = sources.some(source => source.albumId === ALL_DEVICE_MEDIA_ALBUM_ID);
        this.albumIds = watchesWholeLibrary
            ? []
            : sources.map(source => source.albumId).filter(albumId => albumId.length > 0);
    }

    //
    // Whether an item is one this source offers. An empty album list means the whole library; a
    // configured list keeps only the albums named in it.
    //
    private isWanted(item: IMediaLibraryItem): boolean {
        if (this.albumIds.length === 0) {
            return true;
        }
        return this.albumIds.includes(item.albumId);
    }

    //
    // Returns one page of the library.
    //
    // A page that the album filter empties still yields its cursor, so the walk carries on to the
    // next page rather than stopping at the first page that happened to hold nothing wanted.
    //
    async listPage(cursor: string | undefined, pageSize: number): Promise<IMediaSourceListPage> {
        const page = listMediaLibraryPage(cursor, pageSize);

        const items: IMediaItem[] = page.items
            .filter(item => this.isWanted(item))
            .map(item => ({
                sourceId: item.id,
                // The path is only known once the item has been opened, which the task does just
                // before handing the item to the import. Until then there is nothing to read.
                filePath: "",
                displayName: item.displayName,
                contentType: item.mimeType,
                size: item.size,
                createdAt: new Date(item.createdAtMs),
            }));

        return { items, nextCursor: page.nextCursor };
    }

    //
    // Copies the item out of the photo library into the sandbox and returns the path the import can
    // read it from. A library item is not a file the import can open, which is why this exists.
    //
    async openItem(item: IMediaItem): Promise<string> {
        return openMediaLibraryItem(item.sourceId);
    }

    //
    // Deletes the sandbox copy the open made. The item itself is untouched: removing it from the
    // device is cleanup, and is a separate, confirmed operation.
    //
    async closeItem(item: IMediaItem): Promise<void> {
        closeMediaLibraryItem(item.sourceId);
    }

    //
    // Asks the platform to delete the named items from the photo library.
    //
    // Both platforms put a system confirmation in front of deleting media the app does not own, so
    // this is one request per batch rather than one per photo. A user who declines, or a platform
    // that refuses, is reported through the error rather than passed over: the caller has to know
    // which photos are still on the device.
    //
    async deleteItems(sourceIds: string[]): Promise<void> {
        const result = deleteMediaLibraryItems(sourceIds);
        if (result.failedIds.length > 0) {
            throw new MediaSourceDeleteError(
                `The photo library did not delete ${result.failedIds.length} item(s).`,
                result.failedIds
            );
        }
    }
}
