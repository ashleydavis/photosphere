import { IMediaItem } from "./media-source";

//
// Decides what the auto-import task should import next.
//
// Nothing in this file touches the filesystem, the task queue or the clock: the current time is
// passed in. That is what makes the pacing testable, because a test can walk time forwards without
// waiting for it.
//
// There are two lanes. The fast lane carries items the watcher reported since the task started, and
// is released in full the moment it is asked for, because a photo the user has just taken should
// appear in the gallery straight away. The backfill lane carries the library that already existed
// when the task started, and is released at a fixed rate so importing years of photos does not make
// the machine unusable.
//

//
// Where the backfill had reached, persisted so a restart resumes rather than rescanning the whole
// library from the beginning.
//
// The position is the source's own paging cursor rather than the id of the last item released,
// because that is what the source can actually be resumed from, and because a composite source's
// item ids and paging cursors are not the same thing.
//
// It only moves once every item of a page has been released, so a crash mid-page resumes at the
// start of that page and re-offers a handful of items rather than losing them. Re-offering is
// harmless: the import deduplicates by content hash.
//
export interface IBackfillCursor {
    // The paging cursor to resume the source listing from. Undefined means the beginning.
    pageCursor: string | undefined;

    // True once the backfill has walked the whole library. A completed backfill is not resumed.
    completed: boolean;
}

//
// A backfill cursor positioned at the beginning of the library.
//
export function createBackfillCursor(): IBackfillCursor {
    return {
        pageCursor: undefined,
        completed: false,
    };
}

//
// The two lanes and the rate limiter that paces the second one.
//
export class AutoImportQueue {
    // How many backfill items may be released per minute.
    private readonly backfillItemsPerMinute: number;

    // Where the backfill has reached, handed in at construction so a restart resumes.
    private readonly backfillCursor: IBackfillCursor;

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

    // The cursor of the page after the one currently in the backfill lane, held back until that
    // page has been released in full.
    private pendingPageCursor: string | undefined;

    // Whether there is a page cursor waiting to be published. Kept separate from the cursor itself
    // because undefined is a meaningful cursor value: it means the listing is finished.
    private hasPendingPage = false;

    constructor(backfillItemsPerMinute: number, backfillCursor: IBackfillCursor) {
        this.backfillItemsPerMinute = backfillItemsPerMinute;
        this.backfillCursor = backfillCursor;
    }

    //
    // Offers items the watcher has just reported. Returns how many were accepted; the rest were
    // already queued.
    //
    addFastLaneItems(items: IMediaItem[]): number {
        return this.addItems(items, this.fastLane);
    }

    //
    // Offers a page of the existing library to the backfill lane, together with the cursor the page
    // after it starts at (undefined when this was the last page). Returns how many items were
    // accepted.
    //
    // The cursor is not published until every item of the page has been released, so the persisted
    // position never runs ahead of what has actually been imported.
    //
    addBackfillItems(items: IMediaItem[], nextPageCursor: string | undefined): number {
        const accepted = this.addItems(items, this.backfillLane);
        this.pendingPageCursor = nextPageCursor;
        this.hasPendingPage = true;
        this.publishPageCursorIfDrained();
        return accepted;
    }

    //
    // Moves the persisted position on to the page just finished, once the lane holding it is empty.
    // A page that came back with no next cursor was the last one, so the backfill is finished.
    //
    private publishPageCursorIfDrained(): void {
        if (!this.hasPendingPage || this.backfillLane.length > 0) {
            return;
        }

        this.backfillCursor.pageCursor = this.pendingPageCursor;
        if (this.pendingPageCursor === undefined) {
            this.backfillCursor.completed = true;
        }
        this.hasPendingPage = false;
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
    // Returns what should be imported next: every fast-lane item, plus as many backfill items as
    // the rate allows. Returns an empty list when there is nothing to release yet.
    //
    nextBatch(nowMs: number): IMediaItem[] {
        this.topUpBackfillBudget(nowMs);

        const batch = this.fastLane;
        this.fastLane = [];

        while (this.backfillTokens >= 1 && this.backfillLane.length > 0) {
            const item = this.backfillLane.shift()!;
            this.backfillTokens -= 1;
            batch.push(item);
        }

        this.publishPageCursorIfDrained();

        return batch;
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

    //
    // True when the backfill needs another page: it is not finished, nothing is buffered, and no
    // page is waiting to be published.
    //
    needsBackfillPage(): boolean {
        return !this.backfillCursor.completed && this.backfillLane.length === 0 && !this.hasPendingPage;
    }

    //
    // Where the backfill has reached. The task persists this so a restart resumes here.
    //
    getBackfillCursor(): IBackfillCursor {
        return this.backfillCursor;
    }

    //
    // True once the whole library has been walked.
    //
    isBackfillComplete(): boolean {
        return this.backfillCursor.completed;
    }
}
