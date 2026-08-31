import { IMediaItem } from "./media-source";

//
// Holds the media the auto-import task has been offered and hands it out one item at a time.
//
// One queue, and nothing in it waits on a clock.
//
// There used to be two, and a rate limit. A "fast lane" was meant to carry photos a watcher had
// just reported, ahead of a "backfill lane" carrying the library that already existed, which was
// released at a fixed number of items a minute so that importing years of photos would not make the
// machine unusable. Both halves of that turned out to be untrue of this codebase: nothing ever put
// anything in the fast lane, because there is no watcher and never was, so every photo went through
// the paced lane; and no measurement was ever taken of the machine being made unusable, before or
// after. The limit was the whole reason an import of a real library took forty-five minutes.
//
// So there is one queue and no pacing. New photos are found by the scan reading the source from the
// start again on its next run, which is the only mechanism there has ever been.
//
export class AutoImportQueue {
    // Items waiting to be imported, oldest offer first.
    private waiting: IMediaItem[] = [];

    // Every source id that has been queued, so re-listing a source (which happens on every poll)
    // does not queue the same item a second time.
    private queuedSourceIds = new Set<string>();

    //
    // Offers items to the queue. Returns how many were accepted; the rest were already queued.
    //
    addItems(items: IMediaItem[]): number {
        let accepted = 0;
        for (const item of items) {
            if (this.queuedSourceIds.has(item.sourceId)) {
                continue;
            }
            this.queuedSourceIds.add(item.sourceId);
            this.waiting.push(item);
            accepted += 1;
        }

        return accepted;
    }

    //
    // Returns the item that should be imported next, or undefined when nothing is waiting.
    //
    nextItem(): IMediaItem | undefined {
        return this.waiting.shift();
    }

    //
    // True while there are items waiting to be released. The scan uses this to know when to ask the
    // source for its next page, so the cursor does not run ahead of what has been imported.
    //
    hasPending(): boolean {
        return this.waiting.length > 0;
    }

    //
    // How many items are waiting and not yet released.
    //
    pendingCount(): number {
        return this.waiting.length;
    }
}
