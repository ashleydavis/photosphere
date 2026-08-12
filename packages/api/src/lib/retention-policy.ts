//
// Which local original files may be dropped once the remote holds them.
//
// The local database becomes a partial replica of its remote once the two are connected, which
// means it does not have to keep every original on the device: an original the remote holds can be
// fetched again when it is wanted. These policies decide which ones go.
//
// The one rule none of them may break is that a file the origin does not hold, with a matching
// hash, is never evicted. Everything else here is a preference; that one is the difference between
// saving space and losing the user's photo.
//

//
// One local original that could be dropped.
//
export interface IEvictionCandidate {
    // The asset the original belongs to.
    assetId: string;

    // How many bytes the local original occupies.
    originalSizeBytes: number;

    // When the asset was imported, in milliseconds since the epoch.
    importedAtMs: number;

    // When the asset was last looked at, in milliseconds since the epoch, or undefined when it has
    // never been looked at or nothing recorded it.
    lastViewedAtMs: number | undefined;

    // Whether the origin holds this original with a matching hash. False means it must be kept,
    // whatever the policy would otherwise prefer.
    confirmedOnOrigin: boolean;
}

//
// What the policies know about the device beyond the candidates themselves.
//
export interface IRetentionContext {
    // How many bytes of local originals there are in total, including candidates that cannot be
    // evicted.
    totalLocalOriginalBytes: number;

    // How many bytes are free on the device.
    deviceFreeBytes: number;

    // The current time in milliseconds since the epoch.
    nowMs: number;
}

//
// Chooses which local originals to drop.
//
export interface IRetentionPolicy {
    //
    // Returns the asset ids whose local original should be dropped, most preferred first.
    //
    selectForEviction(candidates: IEvictionCandidate[], context: IRetentionContext): string[];
}

//
// The candidates that may be evicted at all, oldest first.
//
// Age is measured by when the asset was imported, not when it was last viewed, because import time
// is always known and last-viewed often is not. Ties are broken by asset id so two runs over the
// same library make the same choice.
//
function evictableOldestFirst(candidates: IEvictionCandidate[]): IEvictionCandidate[] {
    return candidates
        .filter(candidate => candidate.confirmedOnOrigin)
        .slice()
        .sort((left, right) => {
            if (left.importedAtMs !== right.importedAtMs) {
                return left.importedAtMs - right.importedAtMs;
            }
            return left.assetId.localeCompare(right.assetId);
        });
}

//
// Keeps the local originals under a byte cap, dropping the oldest confirmed ones until they fit.
//
export class SizeBudgetRetentionPolicy implements IRetentionPolicy {
    // The most bytes of local originals to keep.
    private readonly budgetBytes: number;

    constructor(budgetBytes: number) {
        this.budgetBytes = budgetBytes;
    }

    //
    // Drops the oldest confirmed originals until what is left fits the budget. Originals that
    // cannot be evicted still count towards the total, because they are still on the device.
    //
    selectForEviction(candidates: IEvictionCandidate[], context: IRetentionContext): string[] {
        let remainingBytes = context.totalLocalOriginalBytes;
        if (remainingBytes <= this.budgetBytes) {
            return [];
        }

        const selected: string[] = [];
        for (const candidate of evictableOldestFirst(candidates)) {
            if (remainingBytes <= this.budgetBytes) {
                break;
            }
            selected.push(candidate.assetId);
            remainingBytes -= candidate.originalSizeBytes;
        }
        return selected;
    }
}

//
// Keeps only recent local originals, dropping confirmed ones older than a number of days.
//
export class RecentDaysRetentionPolicy implements IRetentionPolicy {
    // How many days of originals to keep on the device.
    private readonly days: number;

    constructor(days: number) {
        this.days = days;
    }

    //
    // Drops every confirmed original imported longer ago than the configured number of days.
    //
    selectForEviction(candidates: IEvictionCandidate[], context: IRetentionContext): string[] {
        const cutoffMs = context.nowMs - (this.days * 24 * 60 * 60 * 1000);
        return evictableOldestFirst(candidates)
            .filter(candidate => candidate.importedAtMs < cutoffMs)
            .map(candidate => candidate.assetId);
    }
}

//
// Keeps the device from filling up, dropping the oldest confirmed originals until there is enough
// free space.
//
export class FreeSpaceRetentionPolicy implements IRetentionPolicy {
    // How many bytes must be free on the device.
    private readonly requiredFreeBytes: number;

    constructor(requiredFreeBytes: number) {
        this.requiredFreeBytes = requiredFreeBytes;
    }

    //
    // Drops the oldest confirmed originals until the space they free brings the device above the
    // threshold.
    //
    selectForEviction(candidates: IEvictionCandidate[], context: IRetentionContext): string[] {
        let freeBytes = context.deviceFreeBytes;
        if (freeBytes >= this.requiredFreeBytes) {
            return [];
        }

        const selected: string[] = [];
        for (const candidate of evictableOldestFirst(candidates)) {
            if (freeBytes >= this.requiredFreeBytes) {
                break;
            }
            selected.push(candidate.assetId);
            freeBytes += candidate.originalSizeBytes;
        }
        return selected;
    }
}

//
// Keeps no local originals at all beyond what the remote does not have. The smallest possible local
// database, at the cost of fetching an original from the remote every time one is wanted.
//
export class DropWhenConfirmedRetentionPolicy implements IRetentionPolicy {
    //
    // Drops every confirmed original.
    //
    selectForEviction(candidates: IEvictionCandidate[], context: IRetentionContext): string[] {
        return evictableOldestFirst(candidates).map(candidate => candidate.assetId);
    }
}

//
// Two gigabytes, the cap the size budget policy uses below.
//
const DEFAULT_LOCAL_ORIGINAL_BUDGET_BYTES = 2 * 1024 * 1024 * 1024;

//
// The policy the eviction task actually uses.
//
// Switching policy is uncommenting one of the lines below and commenting out this one. All four are
// implemented and tested, so none of them is a stub waiting to be finished.
//
export const ACTIVE_RETENTION_POLICY: IRetentionPolicy = new SizeBudgetRetentionPolicy(DEFAULT_LOCAL_ORIGINAL_BUDGET_BYTES);
// export const ACTIVE_RETENTION_POLICY: IRetentionPolicy = new RecentDaysRetentionPolicy(30);
// export const ACTIVE_RETENTION_POLICY: IRetentionPolicy = new FreeSpaceRetentionPolicy(5 * 1024 * 1024 * 1024);
// export const ACTIVE_RETENTION_POLICY: IRetentionPolicy = new DropWhenConfirmedRetentionPolicy();
