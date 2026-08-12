import { IAutoImportSource } from "api";
import { IUuidGenerator } from "utils";
import {
    IMediaItem,
    IMediaSource,
    IMediaSourceChangedCallback,
    IMediaSourceListPage,
    IMediaSourceUnsubscribe,
} from "./media-source";

//
// How the auto-import task turns the configured sources into something it can read from.
//
// The task cannot import the implementations directly, because the folder implementation lives here
// in node-api and the device photo library implementation lives in the mobile worker package.
// Instead each platform registers a builder for the source types it can serve, and the task asks
// for whatever the settings name. A source type nobody registered fails loudly rather than being
// quietly skipped, because skipping it would mean silently backing up none of the user's photos.
//

//
// What a builder needs besides the sources themselves.
//
export interface IMediaSourceBuildOptions {
    // How often the source should re-check itself for changes, in milliseconds.
    pollIntervalMs: number;

    // A directory the source may use for temporary files, such as media exported out of the device
    // photo library or extracted from a zip archive.
    sessionTempDir: string;

    // Generates names for those temporary files.
    uuidGenerator: IUuidGenerator;
}

//
// Builds one media source covering every configured source of a single type.
//
export type IMediaSourceBuilder = (sources: IAutoImportSource[], options: IMediaSourceBuildOptions) => IMediaSource;

//
// The builders registered by this platform, by source type.
//
const mediaSourceBuilders = new Map<string, IMediaSourceBuilder>();

//
// Registers the builder for a source type. Called once per type at startup by the platform that can
// serve it: node-api registers folders, the mobile worker registers the device photo library.
//
export function registerMediaSourceBuilder(sourceType: string, builder: IMediaSourceBuilder): void {
    mediaSourceBuilders.set(sourceType, builder);
}

//
// Forgets every registered builder. For tests, so one test's registration does not leak into the
// next.
//
export function clearMediaSourceBuilders(): void {
    mediaSourceBuilders.clear();
}

//
// Builds a single media source covering every configured source, whatever their types.
//
export function buildMediaSource(sources: IAutoImportSource[], options: IMediaSourceBuildOptions): IMediaSource {
    if (sources.length === 0) {
        throw new Error("Cannot build a media source: no automatic import sources are configured.");
    }

    const sourcesByType = new Map<string, IAutoImportSource[]>();
    for (const source of sources) {
        const existing = sourcesByType.get(source.type);
        if (existing) {
            existing.push(source);
        }
        else {
            sourcesByType.set(source.type, [source]);
        }
    }

    const built: IMediaSource[] = [];
    for (const [sourceType, sourcesOfType] of sourcesByType) {
        const builder = mediaSourceBuilders.get(sourceType);
        if (!builder) {
            throw new Error(`No media source builder is registered for source type "${sourceType}" on this platform.`);
        }
        built.push(builder(sourcesOfType, options));
    }

    if (built.length === 1) {
        return built[0];
    }
    return new CompositeMediaSource(built);
}

//
// Splits a composite cursor into the index of the child it belongs to and that child's own cursor.
//
function parseCompositeCursor(cursor: string): ICompositeCursor {
    const separatorIndex = cursor.indexOf("|");
    if (separatorIndex < 0) {
        throw new Error(`Malformed composite media source cursor: "${cursor}".`);
    }
    const childIndex = Number(cursor.slice(0, separatorIndex));
    if (!Number.isInteger(childIndex) || childIndex < 0) {
        throw new Error(`Malformed composite media source cursor: "${cursor}".`);
    }
    const childCursor = cursor.slice(separatorIndex + 1);
    return {
        childIndex,
        childCursor: childCursor.length > 0 ? childCursor : undefined,
    };
}

//
// A position inside a composite listing: which child, and where in that child.
//
interface ICompositeCursor {
    // Index of the child source the listing has reached.
    childIndex: number;

    // The child's own cursor, or undefined at the start of that child.
    childCursor: string | undefined;
}

//
// Presents several media sources as one, by listing them one after another.
//
// This exists for the case where the settings name more than one kind of source at once. The usual
// case is a single kind, and then buildMediaSource returns that source directly rather than wrapping
// it.
//
export class CompositeMediaSource implements IMediaSource {
    // The sources being presented as one, listed in this order.
    private readonly sources: IMediaSource[];

    constructor(sources: IMediaSource[]) {
        this.sources = sources;
    }

    //
    // Returns one page, moving on to the next child source when the current one runs out. Empty
    // children are skipped within the call rather than returning an empty page, which would look
    // like the end of the listing.
    //
    // Every item's source id is stamped with the child it came from, so a later export, release or
    // delete goes back to that child rather than being guessed at.
    //
    async listPage(cursor: string | undefined, pageSize: number): Promise<IMediaSourceListPage> {
        const position: ICompositeCursor = cursor === undefined
            ? { childIndex: 0, childCursor: undefined }
            : parseCompositeCursor(cursor);

        let childIndex = position.childIndex;
        let childCursor = position.childCursor;

        while (childIndex < this.sources.length) {
            const page = await this.sources[childIndex].listPage(childCursor, pageSize);
            const items = page.items.map(item => stampChildIndex(item, childIndex));

            if (page.nextCursor !== undefined) {
                return { items, nextCursor: `${childIndex}|${page.nextCursor}` };
            }

            // This child is finished. If it gave us items, hand them back and point at the next
            // child; otherwise carry straight on so an empty source does not end the listing.
            if (items.length > 0) {
                const nextChildIndex = childIndex + 1;
                return {
                    items,
                    nextCursor: nextChildIndex < this.sources.length ? `${nextChildIndex}|` : undefined,
                };
            }

            childIndex += 1;
            childCursor = undefined;
        }

        return { items: [], nextCursor: undefined };
    }

    //
    // Reports a change from any child source.
    //
    watch(onChanged: IMediaSourceChangedCallback): IMediaSourceUnsubscribe {
        const unsubscribes = this.sources.map(source => source.watch(onChanged));
        return () => {
            for (const unsubscribe of unsubscribes) {
                unsubscribe();
            }
        };
    }

    //
    // Exports through the child the item came from.
    //
    async exportItem(item: IMediaItem): Promise<string> {
        const stamped = parseChildIndex(item.sourceId);
        return await this.childAt(stamped.childIndex).exportItem(withSourceId(item, stamped.sourceId));
    }

    //
    // Releases through the child the item came from.
    //
    async releaseItem(item: IMediaItem): Promise<void> {
        const stamped = parseChildIndex(item.sourceId);
        await this.childAt(stamped.childIndex).releaseItem(withSourceId(item, stamped.sourceId));
    }

    //
    // Deletes each id through the child it came from, so no child is ever handed another child's
    // ids.
    //
    async deleteItems(sourceIds: string[]): Promise<void> {
        const idsByChild = new Map<number, string[]>();
        for (const sourceId of sourceIds) {
            const stamped = parseChildIndex(sourceId);
            const existing = idsByChild.get(stamped.childIndex);
            if (existing) {
                existing.push(stamped.sourceId);
            }
            else {
                idsByChild.set(stamped.childIndex, [stamped.sourceId]);
            }
        }

        for (const [childIndex, childSourceIds] of idsByChild) {
            await this.childAt(childIndex).deleteItems(childSourceIds);
        }
    }

    //
    // The child at an index, or a loud failure when the index names no child. An id that arrived
    // from somewhere else must not be quietly handed to the wrong source.
    //
    private childAt(childIndex: number): IMediaSource {
        const source = this.sources[childIndex];
        if (!source) {
            throw new Error(`Composite media source has no child at index ${childIndex}.`);
        }
        return source;
    }
}

//
// Records which child an item came from, in the only field that travels with it everywhere.
//
function stampChildIndex(item: IMediaItem, childIndex: number): IMediaItem {
    return { ...item, sourceId: `${childIndex}#${item.sourceId}` };
}

//
// Reads back the child index a source id was stamped with.
//
function parseChildIndex(stampedSourceId: string): IStampedSourceId {
    const separatorIndex = stampedSourceId.indexOf("#");
    if (separatorIndex < 0) {
        throw new Error(`Source id "${stampedSourceId}" did not come from this composite media source.`);
    }

    const childIndex = Number(stampedSourceId.slice(0, separatorIndex));
    if (!Number.isInteger(childIndex) || childIndex < 0) {
        throw new Error(`Source id "${stampedSourceId}" did not come from this composite media source.`);
    }

    return { childIndex, sourceId: stampedSourceId.slice(separatorIndex + 1) };
}

//
// A copy of an item carrying the child's own source id rather than the stamped one.
//
function withSourceId(item: IMediaItem, sourceId: string): IMediaItem {
    return { ...item, sourceId };
}

//
// A source id together with the child it belongs to.
//
interface IStampedSourceId {
    // Index of the child source the id came from.
    childIndex: number;

    // The child's own source id, with the stamp removed.
    sourceId: string;
}
