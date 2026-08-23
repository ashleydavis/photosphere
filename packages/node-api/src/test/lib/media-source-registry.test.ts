import { IAutoImportSource } from "api";
import { RandomUuidGenerator } from "utils";
import {
    IMediaItem,
    IMediaSource,
    IMediaSourceListPage,
} from "../../lib/media-source";
import {
    buildMediaSource,
    clearMediaSourceBuilders,
    CompositeMediaSource,
    IMediaSourceBuildOptions,
    registerMediaSourceBuilder,
} from "../../lib/media-source-registry";

//
// A media source over a fixed list of items, so the composite's paging and routing can be tested
// without touching a filesystem or a photo library.
//
class ListMediaSource implements IMediaSource {
    // The source ids this source was asked to delete, in order.
    readonly deleteRequests: string[][] = [];

    // The items exported through this source, in order.
    readonly exported: string[] = [];

    // The items released through this source, in order.
    readonly released: string[] = [];

    private readonly items: IMediaItem[];

    constructor(private readonly label: string, itemNames: string[]) {
        this.items = itemNames.map(name => ({
            sourceId: `${label}/${name}`,
            filePath: `/${label}/${name}`,
            displayName: name,
            contentType: "image/jpeg",
            size: 100,
            createdAt: new Date("2026-01-01T00:00:00.000Z"),
        }));
    }

    async listPage(cursor: string | undefined, pageSize: number): Promise<IMediaSourceListPage> {
        const startIndex = cursor === undefined ? 0 : this.items.findIndex(item => item.sourceId === cursor) + 1;
        const page = this.items.slice(startIndex, startIndex + pageSize);
        const endIndex = startIndex + page.length;
        return {
            items: page,
            nextCursor: endIndex < this.items.length && page.length > 0 ? page[page.length - 1].sourceId : undefined,
        };
    }

    async openItem(item: IMediaItem): Promise<string> {
        this.exported.push(item.sourceId);
        return item.filePath;
    }

    async closeItem(item: IMediaItem): Promise<void> {
        this.released.push(item.sourceId);
    }

    async deleteItems(sourceIds: string[]): Promise<void> {
        this.deleteRequests.push([...sourceIds]);
    }
}

//
// The options every builder is handed. Nothing here cares what they are.
//
const buildOptions: IMediaSourceBuildOptions = {
    sessionTempDir: "/tmp/session",
    uuidGenerator: new RandomUuidGenerator(),
};

describe("the media source registry", () => {

    beforeEach(() => {
        clearMediaSourceBuilders();
    });

    afterEach(() => {
        clearMediaSourceBuilders();
    });

    test("refuses to build from no sources at all", () => {
        expect(() => buildMediaSource([], buildOptions)).toThrow(/no automatic import sources/i);
    });

    test("fails loudly for a source type nobody registered", () => {
        const sources: IAutoImportSource[] = [{ type: "device-album", albumId: "camera" }];

        expect(() => buildMediaSource(sources, buildOptions)).toThrow(/no media source builder is registered/i);
    });

    test("a single registered type is built directly, without a composite", () => {
        const built = new ListMediaSource("folder", ["a.jpg"]);
        registerMediaSourceBuilder("folder", () => built);

        const source = buildMediaSource([{ type: "folder", path: "/photos", recurse: true }], buildOptions);

        expect(source).toBe(built);
    });

    test("every source of one type is handed to that type's builder at once", () => {
        let handedOver: IAutoImportSource[] = [];
        registerMediaSourceBuilder("folder", sources => {
            handedOver = sources;
            return new ListMediaSource("folder", []);
        });

        buildMediaSource([
            { type: "folder", path: "/one", recurse: true },
            { type: "folder", path: "/two", recurse: false },
        ], buildOptions);

        expect(handedOver).toHaveLength(2);
    });

    test("two types are presented as one composite source", async () => {
        registerMediaSourceBuilder("folder", () => new ListMediaSource("folder", ["a.jpg"]));
        registerMediaSourceBuilder("device-album", () => new ListMediaSource("album", ["b.jpg"]));

        const source = buildMediaSource([
            { type: "folder", path: "/photos", recurse: true },
            { type: "device-album", albumId: "camera" },
        ], buildOptions);

        expect(source).toBeInstanceOf(CompositeMediaSource);
    });

    test("the options are passed through to the builder", () => {
        let seenOptions: IMediaSourceBuildOptions | undefined = undefined;
        registerMediaSourceBuilder("folder", (sources, options) => {
            seenOptions = options;
            return new ListMediaSource("folder", []);
        });

        buildMediaSource([{ type: "folder", path: "/photos", recurse: true }], buildOptions);

        expect(seenOptions).toBe(buildOptions);
    });
});

describe("CompositeMediaSource", () => {

    //
    // Drains every page of a source into one list.
    //
    async function listAll(source: IMediaSource, pageSize: number): Promise<IMediaItem[]> {
        const items: IMediaItem[] = [];
        let cursor: string | undefined = undefined;
        let pages = 0;
        do {
            const page: IMediaSourceListPage = await source.listPage(cursor, pageSize);
            items.push(...page.items);
            cursor = page.nextCursor;
            pages += 1;
            if (pages > 50) {
                throw new Error("Paging did not terminate.");
            }
        } while (cursor !== undefined);
        return items;
    }

    test("lists both children, one after the other", async () => {
        const first = new ListMediaSource("first", ["a.jpg", "b.jpg"]);
        const second = new ListMediaSource("second", ["c.jpg"]);

        const items = await listAll(new CompositeMediaSource([first, second]), 10);

        expect(items.map(item => item.displayName)).toEqual(["a.jpg", "b.jpg", "c.jpg"]);
    });

    test("pages across the boundary between children", async () => {
        const first = new ListMediaSource("first", ["a.jpg", "b.jpg", "c.jpg"]);
        const second = new ListMediaSource("second", ["d.jpg", "e.jpg"]);

        const items = await listAll(new CompositeMediaSource([first, second]), 2);

        expect(items.map(item => item.displayName)).toEqual(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"]);
    });

    test("an empty child does not end the listing", async () => {
        const composite = new CompositeMediaSource([
            new ListMediaSource("empty", []),
            new ListMediaSource("second", ["a.jpg"]),
        ]);

        const items = await listAll(composite, 10);

        expect(items.map(item => item.displayName)).toEqual(["a.jpg"]);
    });

    test("a composite of empty children lists nothing", async () => {
        const composite = new CompositeMediaSource([new ListMediaSource("one", []), new ListMediaSource("two", [])]);

        expect(await listAll(composite, 10)).toEqual([]);
    });

    test("each item says which child it came from", async () => {
        const composite = new CompositeMediaSource([
            new ListMediaSource("first", ["a.jpg"]),
            new ListMediaSource("second", ["b.jpg"]),
        ]);

        const items = await listAll(composite, 10);

        expect(items[0].sourceId).toBe("0#first/a.jpg");
        expect(items[1].sourceId).toBe("1#second/b.jpg");
    });

    test("exporting goes to the child the item came from, with the stamp removed", async () => {
        const first = new ListMediaSource("first", ["a.jpg"]);
        const second = new ListMediaSource("second", ["b.jpg"]);
        const composite = new CompositeMediaSource([first, second]);

        const items = await listAll(composite, 10);
        await composite.openItem(items[1]);

        expect(first.exported).toEqual([]);
        expect(second.exported).toEqual(["second/b.jpg"]);
    });

    test("releasing goes to the child the item came from", async () => {
        const first = new ListMediaSource("first", ["a.jpg"]);
        const second = new ListMediaSource("second", ["b.jpg"]);
        const composite = new CompositeMediaSource([first, second]);

        const items = await listAll(composite, 10);
        await composite.closeItem(items[0]);

        expect(first.released).toEqual(["first/a.jpg"]);
        expect(second.released).toEqual([]);
    });

    test("each child is asked to delete only its own ids", async () => {
        const first = new ListMediaSource("first", ["a.jpg"]);
        const second = new ListMediaSource("second", ["b.jpg"]);
        const composite = new CompositeMediaSource([first, second]);

        const items = await listAll(composite, 10);
        await composite.deleteItems(items.map(item => item.sourceId));

        expect(first.deleteRequests).toEqual([["first/a.jpg"]]);
        expect(second.deleteRequests).toEqual([["second/b.jpg"]]);
    });

    test("a child with nothing to delete is not asked", async () => {
        const first = new ListMediaSource("first", ["a.jpg"]);
        const second = new ListMediaSource("second", ["b.jpg"]);
        const composite = new CompositeMediaSource([first, second]);

        const items = await listAll(composite, 10);
        await composite.deleteItems([items[0].sourceId]);

        expect(first.deleteRequests).toEqual([["first/a.jpg"]]);
        expect(second.deleteRequests).toEqual([]);
    });

    test("an id that did not come from this composite is refused rather than handed to a child", async () => {
        const composite = new CompositeMediaSource([new ListMediaSource("first", ["a.jpg"])]);

        await expect(composite.deleteItems(["/somewhere/else.jpg"])).rejects.toThrow(/did not come from this composite/i);
    });

    test("an id naming a child that does not exist is refused", async () => {
        const composite = new CompositeMediaSource([new ListMediaSource("first", ["a.jpg"])]);

        await expect(composite.deleteItems(["7#first/a.jpg"])).rejects.toThrow(/no child at index 7/i);
    });

    test("a malformed cursor is refused rather than silently starting over", async () => {
        const composite = new CompositeMediaSource([new ListMediaSource("first", ["a.jpg"])]);

        await expect(composite.listPage("not-a-cursor", 10)).rejects.toThrow(/malformed composite/i);
    });
});
