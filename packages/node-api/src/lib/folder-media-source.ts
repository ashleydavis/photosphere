import * as fs from "fs";
import * as fsPromises from "fs/promises";
import * as path from "path";
import { IFolderAutoImportSource } from "api";
import { IUuidGenerator, log } from "utils";
import { scanPaths } from "./file-scanner";
import {
    IMediaItem,
    IMediaSource,
    IMediaSourceChangedCallback,
    IMediaSourceListPage,
    IMediaSourceUnsubscribe,
    MediaSourceDeleteError,
} from "./media-source";

//
// A media source over folders on the local filesystem, used by the CLI and the desktop app.
//
// Enumeration goes through the existing `scanPaths`, so the content-type filtering and zip handling
// the manual import already does are reused rather than written a second time.
//

//
// The platforms whose fs.watch supports watching a directory tree in one call. On Linux it does not,
// which is exactly why the poll below exists rather than being a belt-and-braces extra.
//
const RECURSIVE_WATCH_PLATFORMS: NodeJS.Platform[] = ["win32", "darwin"];

//
// An item found by a scan, together with where it really lives on disk. A file inside a zip has no
// disk path of its own, which is what stops the cleanup deleting it.
//
interface IScannedItem {
    // The item as the auto-import task sees it.
    item: IMediaItem;

    // The file on disk backing the item, or undefined when it came out of a zip archive.
    diskPath: string | undefined;
}

//
// A media source over a list of watched folders.
//
export class FolderMediaSource implements IMediaSource {
    // The folders being watched, each with its own recurse flag.
    private readonly folders: IFolderAutoImportSource[];

    // How often the folders are re-listed, in milliseconds.
    private readonly pollIntervalMs: number;

    // Temporary directory the scanner extracts zip members into.
    private readonly sessionTempDir: string;

    // Generates the names of extracted temporary files.
    private readonly uuidGenerator: IUuidGenerator;

    // The most recent scan, kept so paging through a large library does not rescan for every page.
    // Dropped when the watcher reports a change, or when the cursor is not in it.
    private scannedItems: IScannedItem[] | undefined;

    // Where each scanned item really lives on disk, by source id. Populated by scanning and used by
    // deleteItems, so cleanup never guesses at a path.
    private diskPathsBySourceId = new Map<string, string>();

    constructor(folders: IFolderAutoImportSource[], pollIntervalMs: number, sessionTempDir: string, uuidGenerator: IUuidGenerator) {
        this.folders = folders;
        this.pollIntervalMs = pollIntervalMs;
        this.sessionTempDir = sessionTempDir;
        this.uuidGenerator = uuidGenerator;
    }

    //
    // Walks every watched folder and returns what is there now, in a stable order.
    //
    private async scan(): Promise<IScannedItem[]> {
        const scanned: IScannedItem[] = [];

        for (const folder of this.folders) {
            const folderPath = path.resolve(folder.path);

            await scanPaths(
                [folderPath],
                async result => {
                    // A non-recursive folder takes only the files sitting directly in it. The
                    // scanner always walks the whole tree, so the filtering happens here.
                    const isFromZip = result.logicalPath !== result.filePath;
                    if (!folder.recurse && !isFromZip && path.dirname(result.filePath) !== folderPath) {
                        return;
                    }

                    scanned.push({
                        item: {
                            sourceId: result.logicalPath,
                            filePath: result.filePath,
                            displayName: path.basename(result.logicalPath),
                            contentType: result.contentType,
                            size: result.fileStat.length,
                            createdAt: result.fileStat.lastModified,
                        },
                        diskPath: isFromZip ? undefined : result.filePath,
                    });
                },
                undefined,
                { ignorePatterns: [/\.db/] },
                this.sessionTempDir,
                this.uuidGenerator
            );
        }

        // The listing order has to be the same every time, because the backfill cursor is a position
        // in it. The scanner's own order is stable within one folder but says nothing about how two
        // folders sort against each other.
        scanned.sort((left, right) => left.item.sourceId.localeCompare(right.item.sourceId));

        this.diskPathsBySourceId = new Map<string, string>();
        for (const scannedItem of scanned) {
            if (scannedItem.diskPath !== undefined) {
                this.diskPathsBySourceId.set(scannedItem.item.sourceId, scannedItem.diskPath);
            }
        }

        return scanned;
    }

    //
    // Returns one page of the folders' contents, starting after the item named by the cursor.
    //
    async listPage(cursor: string | undefined, pageSize: number): Promise<IMediaSourceListPage> {
        if (cursor === undefined || this.scannedItems === undefined) {
            this.scannedItems = await this.scan();
        }

        let startIndex = 0;
        if (cursor !== undefined) {
            const cursorIndex = this.scannedItems.findIndex(scannedItem => scannedItem.item.sourceId === cursor);
            if (cursorIndex < 0) {
                // The item the cursor named is gone, so the cached listing cannot be trusted to
                // position us. Rescan and resume at the first item that sorts after the cursor,
                // which keeps the backfill moving forwards rather than starting over.
                this.scannedItems = await this.scan();
                startIndex = this.scannedItems.findIndex(scannedItem => scannedItem.item.sourceId.localeCompare(cursor) > 0);
                if (startIndex < 0) {
                    startIndex = this.scannedItems.length;
                }
            }
            else {
                startIndex = cursorIndex + 1;
            }
        }

        const page = this.scannedItems.slice(startIndex, startIndex + pageSize);
        const endIndex = startIndex + page.length;
        return {
            items: page.map(scannedItem => scannedItem.item),
            nextCursor: endIndex < this.scannedItems.length && page.length > 0
                ? page[page.length - 1].item.sourceId
                : undefined,
        };
    }

    //
    // Reports changes to the watched folders, both from the operating system's watcher and from a
    // poll. The poll is not a fallback for the watcher failing to start: recursive watching is not
    // available on Linux and is not dependable across network and removable filesystems anywhere,
    // so the poll is what actually guarantees a new photo is noticed.
    //
    watch(onChanged: IMediaSourceChangedCallback): IMediaSourceUnsubscribe {
        const watchers: fs.FSWatcher[] = [];
        const recursive = RECURSIVE_WATCH_PLATFORMS.includes(process.platform);

        const notifyChanged = (): void => {
            this.scannedItems = undefined;
            onChanged();
        };

        for (const folder of this.folders) {
            const folderPath = path.resolve(folder.path);
            try {
                const watcher = fs.watch(folderPath, { recursive: recursive && folder.recurse }, () => {
                    notifyChanged();
                });
                watcher.on("error", error => {
                    // A watcher that dies leaves the poll doing the work, so this is worth knowing
                    // about but is not a reason to stop importing.
                    log.verbose(`Watcher for "${folderPath}" failed: ${error.message}. The poll will still pick up changes.`);
                });
                watchers.push(watcher);
            }
            catch (error: any) {
                log.verbose(`Could not watch "${folderPath}": ${error.message}. The poll will still pick up changes.`);
            }
        }

        const pollTimer = setInterval(notifyChanged, this.pollIntervalMs);

        return () => {
            clearInterval(pollTimer);
            for (const watcher of watchers) {
                watcher.close();
            }
        };
    }

    //
    // A folder item is already a file, so there is nothing to materialise.
    //
    async exportItem(item: IMediaItem): Promise<string> {
        return item.filePath;
    }

    //
    // Nothing was materialised, so there is nothing to release.
    //
    async releaseItem(item: IMediaItem): Promise<void> {
    }

    //
    // Deletes the named source files. An item that came out of a zip archive has no file of its own
    // to delete, and neither does one this source has never listed, so both are named in the error
    // rather than silently passed over.
    //
    async deleteItems(sourceIds: string[]): Promise<void> {
        const undeletable: string[] = [];

        for (const sourceId of sourceIds) {
            const diskPath = this.diskPathsBySourceId.get(sourceId);
            if (diskPath === undefined) {
                undeletable.push(sourceId);
                continue;
            }

            try {
                await fsPromises.unlink(diskPath);
            }
            catch (error: any) {
                if (error.code === "ENOENT") {
                    // Already gone, which is the outcome the caller asked for.
                    continue;
                }
                undeletable.push(sourceId);
            }
        }

        if (undeletable.length > 0) {
            throw new MediaSourceDeleteError(`Failed to delete ${undeletable.length} source file(s) from the watched folders.`, undeletable);
        }
    }
}
