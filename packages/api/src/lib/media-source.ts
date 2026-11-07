//
// The abstraction the auto-import task scans through.
//
// A media source is somewhere media arrives: a folder on a desktop machine, or the device photo
// library on a phone. The auto-import task only ever talks to this interface, so the same task runs
// unchanged on the CLI, on the desktop and on mobile, and adding a new kind of source does not touch
// the task at all.
//

//
// One piece of media offered by a source.
//
export interface IMediaItem {
    // Identifies this item within its source and does not change between listings. A folder source
    // uses the file's logical path; a device library uses the platform's asset identifier. The
    // auto-import cursor is recorded in terms of these, so it has to be stable across a restart.
    sourceId: string;

    // Where the importer can read the bytes. Absolute on desktop, sandbox-relative on mobile. For a
    // source that materialises a temporary copy this is only valid between openItem and
    // closeItem.
    filePath: string;

    // What to show the user while this item is being imported.
    displayName: string;

    // The MIME type of the item.
    contentType: string;

    // The size of the item in bytes.
    size: number;

    // When the item was created, as far as the source can tell.
    createdAt: Date;
}

//
// One page of a source listing.
//
export interface IMediaSourceListPage {
    // The items in this page, in the source's stable listing order.
    items: IMediaItem[];

    // Where the next page starts. Undefined at the end of the listing.
    nextCursor: string | undefined;
}

//
// Somewhere media arrives that automatic import lists and imports from.
//
export interface IMediaSource {
    //
    // Returns one page of the source's contents. Pass undefined as the cursor to start at the
    // beginning, and the previous page's nextCursor to continue.
    //
    listPage(cursor: string | undefined, pageSize: number): Promise<IMediaSourceListPage>;

    //
    // Returns a path the importer can read the item's bytes from. A source whose items are already
    // files returns the path unchanged; one that has to materialise a copy makes it here.
    //
    openItem(item: IMediaItem): Promise<string>;

    //
    // Releases whatever openItem materialised. Does nothing for a source whose items are already
    // files.
    //
    closeItem(item: IMediaItem): Promise<void>;

    //
    // Deletes the named items from the source. Throws MediaSourceDeleteError naming the items it
    // could not delete, rather than reporting success for work that did not happen.
    //
    deleteItems(sourceIds: string[]): Promise<void>;
}

//
// Thrown when a source is asked to delete items it cannot delete. It names them, so the caller can
// report which source files are still on the device rather than assuming they are gone.
//
export class MediaSourceDeleteError extends Error {
    // The source ids that could not be deleted.
    readonly sourceIds: string[];

    constructor(message: string, sourceIds: string[]) {
        super(message);
        this.name = "MediaSourceDeleteError";
        this.sourceIds = sourceIds;
    }
}
