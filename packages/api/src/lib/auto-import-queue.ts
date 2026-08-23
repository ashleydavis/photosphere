import { IMediaItem } from "./media-source";

//
// Decides what the auto-import task should import next.
//
// Nothing in this file touches the filesystem, the task queue or the clock: the current time is
// passed in. That is what makes the pacing testable, because a test can walk time forwards without
// waiting for it.
//
// There are two lanes. The fast lane carries items the watcher reported since the task started, and
// is released ahead of everything else and on its own, because a photo the user has just taken should
// appear in the gallery straight away. The backfill lane carries the library that already existed
// when the task started, and is released at a fixed rate so importing years of photos does not make
// the machine unusable. Items come out one at a time, so the fast lane is looked at again before
// every single import.
//

//
// The two lanes and the rate limiter that paces the second one.
//
export class AutoImportQueue {
    // How many backfill items may be released per minute.
    private readonly backfillItemsPerMinute: number;

    // Items the watcher reported since the task started, released as soon as they are asked for.
    private fastLane: IMediaItem[] = [];

    // Items from the library that already existed, released at the configured rate.
    private backfillLane: IMediaItem[] = [];

    // Every source id that has been queued in either lane, so re-listing a source (which happens on
    // every poll) does not queue the same item a second time.
    private queuedSourceIds = new Set<string>();

    // The rate limiter's budget, in items. One whole token releases one backfill item.
    private backfillTokens = 0;

    // When the budget was last topped up. Undefined until the first batch is asked for, so the
    // clock starts when the task starts rather than at some arbitrary earlier moment.
    private lastToppedUpMs: number | undefined;

    constructor(backfillItemsPerMinute: number) {
        this.backfillItemsPerMinute = backfillItemsPerMinute;
    }

    //
    // Offers items the watcher has just reported. Returns how many were accepted; the rest were
    // already queued.
    //
    addFastLaneItems(items: IMediaItem[]): number {
        return this.addItems(items, this.fastLane);
    }

    //
    // Offers a page of the existing library to the backfill lane. Returns how many items were
    // accepted; the rest were already queued.
    //
    addBackfillItems(items: IMediaItem[]): number {
        return this.addItems(items, this.backfillLane);
    }

    //
    // Adds the items that have not been queued before to a lane.
    //
    private addItems(items: IMediaItem[], lane: IMediaItem[]): number {
        let accepted = 0;
        for (const item of items) {
            if (this.queuedSourceIds.has(item.sourceId)) {
                continue;
            }
            this.queuedSourceIds.add(item.sourceId);
            lane.push(item);
            accepted += 1;
        }
        return accepted;
    }

    //
    // Adds the budget earned since the last top-up.
    //
    // The budget is capped at one minute's worth so a task that sat idle for an hour does not then
    // release an hour's allowance at once, which would defeat the point of pacing.
    //
    private topUpBackfillBudget(nowMs: number): void {
        if (this.lastToppedUpMs === undefined) {
            this.lastToppedUpMs = nowMs;
            return;
        }

        const elapsedMs = nowMs - this.lastToppedUpMs;
        if (elapsedMs <= 0) {
            return;
        }

        this.lastToppedUpMs = nowMs;
        this.backfillTokens = Math.min(
            this.backfillItemsPerMinute,
            this.backfillTokens + (elapsedMs * this.backfillItemsPerMinute) / 60000
        );
    }

    //
    // Returns the one item that should be imported next, or undefined when there is nothing to
    // release yet.
    //
    // The fast lane always goes first, and because this hands out one item at a time the lane is
    // looked at again before every single import. A photo the user has just taken is therefore
    // never behind more than one already-released backfill item, however far behind the backfill
    // is. This used to hand out a batch, which meant the caller went blind for the length of that
    // batch and the fast lane had to be given a whole batch to itself to compensate.
    //
    nextItem(nowMs: number): IMediaItem | undefined {
        this.topUpBackfillBudget(nowMs);

        const arrival = this.fastLane.shift();
        if (arrival !== undefined) {
            return arrival;
        }

        if (this.backfillTokens < 1 || this.backfillLane.length === 0) {
            return undefined;
        }

        const existing = this.backfillLane.shift()!;
        this.backfillTokens -= 1;
        return existing;
    }

    //
    // True while there are backfill items waiting to be released. The task uses this to know when
    // to ask the source for the next page: fetching earlier would buffer items the pacing has not
    // reached, and would move the cursor ahead of what has actually been imported.
    //
    hasPendingBackfill(): boolean {
        return this.backfillLane.length > 0;
    }

    //
    // How many backfill items are buffered and not yet released.
    //
    pendingBackfillCount(): number {
        return this.backfillLane.length;
    }

    //
    // True while there are watcher items waiting to be released.
    //
    hasPendingFastLane(): boolean {
        return this.fastLane.length > 0;
    }

}
