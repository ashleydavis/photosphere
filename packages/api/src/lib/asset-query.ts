import * as path from "node:path";
import * as fs from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { pipeline } from "node:stream/promises";
import type { IBsonDatabase } from "bdb";
import type { IStorage } from "storage";
import type { IAsset } from "./asset";

//
// Result of a paginated asset listing.
//
export interface IListAssetsResult {
    //
    // Page of assets.
    //
    assets: IAsset[];

    //
    // Opaque token to pass back for the next page. Undefined when there are no more pages.
    //
    nextPageId?: string;
}

//
// Asset type used by export operations. Maps to a storage prefix.
//
export type AssetExportType = "original" | "display" | "thumb";

//
// Returns one page of assets from the metadata collection, sorted by photoDate descending.
//
export async function listAssetPage(bsonDatabase: IBsonDatabase, limit: number, pageId: string | undefined): Promise<IListAssetsResult> {
    const metadataCollection = bsonDatabase.collection<IAsset>("metadata");
    const page = await metadataCollection.sortIndex("photoDate", "desc").getPage(pageId);
    const assets = page.records.slice(0, limit) as IAsset[];
    return {
        assets,
        nextPageId: page.nextPageId,
    };
}

//
// Searches assets in the metadata collection using an in-memory filter.
// Matches case-insensitive substring on origFileName and location, prefix on contentType,
// and a date range on photoDate.
//
export async function searchAssets(
    bsonDatabase: IBsonDatabase,
    query: string,
    contentType: string | undefined,
    dateFrom: string | undefined,
    dateTo: string | undefined,
    limit: number,
): Promise<IAsset[]> {
    const metadataCollection = bsonDatabase.collection<IAsset>("metadata");

    const queryLower = query.toLowerCase();
    const contentTypePrefix = contentType ? contentType.toLowerCase() : undefined;
    const dateFromMs = dateFrom ? Date.parse(dateFrom) : undefined;
    const dateToMs = dateTo ? Date.parse(dateTo) : undefined;

    const matches: IAsset[] = [];

    let nextToken: string | undefined = undefined;
    do {
        const pageResult = await metadataCollection.getAll(nextToken);
        for (const asset of pageResult.records) {
            if (!matchesAsset(asset, queryLower, contentTypePrefix, dateFromMs, dateToMs)) {
                continue;
            }
            matches.push(asset);
            if (matches.length >= limit) {
                return matches;
            }
        }
        nextToken = pageResult.next;
    }
    while (nextToken);

    return matches;
}

//
// True if the asset matches all of the supplied filters.
//
function matchesAsset(
    asset: IAsset,
    queryLower: string,
    contentTypePrefix: string | undefined,
    dateFromMs: number | undefined,
    dateToMs: number | undefined,
): boolean {
    if (queryLower.length > 0) {
        const origFileName = (asset.origFileName || "").toLowerCase();
        const location = (asset.location || "").toLowerCase();
        if (!origFileName.includes(queryLower) && !location.includes(queryLower)) {
            return false;
        }
    }
    if (contentTypePrefix) {
        const ct = (asset.contentType || "").toLowerCase();
        if (!ct.startsWith(contentTypePrefix)) {
            return false;
        }
    }
    if (dateFromMs !== undefined || dateToMs !== undefined) {
        if (!asset.photoDate) {
            return false;
        }
        const photoMs = Date.parse(asset.photoDate);
        if (Number.isNaN(photoMs)) {
            return false;
        }
        if (dateFromMs !== undefined && photoMs < dateFromMs) {
            return false;
        }
        if (dateToMs !== undefined && photoMs > dateToMs) {
            return false;
        }
    }
    return true;
}

//
// Returns a single asset by id, or undefined if not found.
//
export async function getAsset(bsonDatabase: IBsonDatabase, assetId: string): Promise<IAsset | undefined> {
    const metadataCollection = bsonDatabase.collection<IAsset>("metadata");
    return metadataCollection.getOne(assetId);
}

//
// Streams an asset from storage to a file on disk and returns the number of bytes written.
// Maps type to a storage prefix (asset/, display/, thumb/) and creates parent directories.
//
export async function streamAssetToFile(
    assetStorage: IStorage,
    assetId: string,
    outputPath: string,
    type: string,
): Promise<number> {
    const storageKey = mapAssetTypeToStorageKey(type, assetId);
    await fs.mkdir(path.dirname(outputPath), { recursive: true });

    const readStream = await assetStorage.readStream(storageKey);
    let bytesWritten = 0;
    readStream.on("data", chunk => {
        bytesWritten += (chunk as Buffer).length;
    });

    const writeStream = createWriteStream(outputPath);
    await pipeline(readStream, writeStream);
    return bytesWritten;
}

//
// Maps an MCP asset export type to a storage path.
//
function mapAssetTypeToStorageKey(type: string, assetId: string): string {
    switch (type) {
        case "display":
            return `display/${assetId}`;
        case "thumb":
            return `thumb/${assetId}`;
        case "original":
        default:
            return `asset/${assetId}`;
    }
}
