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
// (Zig: the policies are the tagged union RetentionPolicy over four structs, each with its own selectForEviction.
// Byte counts and times are f64.)
//

const std = @import("std");
const bdb = @import("bdb-zig");

//
// One local original that could be dropped.
//
pub const IEvictionCandidate = struct {
    // The asset the original belongs to.
    assetId: []const u8,

    // How many bytes the local original occupies.
    originalSizeBytes: f64,

    // When the asset was imported, in milliseconds since the epoch.
    importedAtMs: f64,

    // When the asset was last looked at, in milliseconds since the epoch, or null when it has
    // never been looked at or nothing recorded it.
    lastViewedAtMs: ?f64,

    // Whether the origin holds this original with a matching hash. False means it must be kept,
    // whatever the policy would otherwise prefer.
    confirmedOnOrigin: bool,
};

//
// What the policies know about the device beyond the candidates themselves.
//
pub const IRetentionContext = struct {
    // How many bytes of local originals there are in total, including candidates that cannot be
    // evicted.
    totalLocalOriginalBytes: f64,

    // How many bytes are free on the device.
    deviceFreeBytes: f64,

    // The current time in milliseconds since the epoch.
    nowMs: f64,
};

//
// Compares two candidates for the order evictableOldestFirst puts them in: oldest import first, then by asset id.
//
fn candidateIsOlder(context: void, left: IEvictionCandidate, right: IEvictionCandidate) bool {
    _ = context;
    if (left.importedAtMs != right.importedAtMs) {
        return left.importedAtMs - right.importedAtMs < 0;
    }
    return bdb.locale_compare.localeCompare(left.assetId, right.assetId) < 0;
}

//
// The candidates that may be evicted at all, oldest first.
//
// Age is measured by when the asset was imported, not when it was last viewed, because import time
// is always known and last-viewed often is not. Ties are broken by asset id so two runs over the
// same library make the same choice.
//
fn evictableOldestFirst(allocator: std.mem.Allocator, candidates: []const IEvictionCandidate) ![]IEvictionCandidate {
    var confirmed: std.ArrayList(IEvictionCandidate) = .empty;
    for (candidates) |candidate| {
        if (candidate.confirmedOnOrigin) {
            try confirmed.append(allocator, candidate);
        }
    }
    std.mem.sort(IEvictionCandidate, confirmed.items, {}, candidateIsOlder);
    return confirmed.items;
}

//
// Keeps the local originals under a byte cap, dropping the oldest confirmed ones until they fit.
//
pub const SizeBudgetRetentionPolicy = struct {
    // The most bytes of local originals to keep.
    budgetBytes: f64,

    //
    // Drops the oldest confirmed originals until what is left fits the budget. Originals that
    // cannot be evicted still count towards the total, because they are still on the device.
    //
    pub fn selectForEviction(self: SizeBudgetRetentionPolicy, allocator: std.mem.Allocator, candidates: []const IEvictionCandidate, context: IRetentionContext) ![]const []const u8 {
        var remainingBytes = context.totalLocalOriginalBytes;
        if (remainingBytes <= self.budgetBytes) {
            return &.{};
        }

        var selected: std.ArrayList([]const u8) = .empty;
        for (try evictableOldestFirst(allocator, candidates)) |candidate| {
            if (remainingBytes <= self.budgetBytes) {
                break;
            }
            try selected.append(allocator, candidate.assetId);
            remainingBytes -= candidate.originalSizeBytes;
        }
        return selected.items;
    }
};

//
// Keeps only recent local originals, dropping confirmed ones older than a number of days.
//
pub const RecentDaysRetentionPolicy = struct {
    // How many days of originals to keep on the device.
    days: f64,

    //
    // Drops every confirmed original imported longer ago than the configured number of days.
    //
    pub fn selectForEviction(self: RecentDaysRetentionPolicy, allocator: std.mem.Allocator, candidates: []const IEvictionCandidate, context: IRetentionContext) ![]const []const u8 {
        const cutoffMs = context.nowMs - (self.days * 24 * 60 * 60 * 1000);
        var selected: std.ArrayList([]const u8) = .empty;
        for (try evictableOldestFirst(allocator, candidates)) |candidate| {
            if (candidate.importedAtMs < cutoffMs) {
                try selected.append(allocator, candidate.assetId);
            }
        }
        return selected.items;
    }
};

//
// Keeps the device from filling up, dropping the oldest confirmed originals until there is enough
// free space.
//
pub const FreeSpaceRetentionPolicy = struct {
    // How many bytes must be free on the device.
    requiredFreeBytes: f64,

    //
    // Drops the oldest confirmed originals until the space they free brings the device above the
    // threshold.
    //
    pub fn selectForEviction(self: FreeSpaceRetentionPolicy, allocator: std.mem.Allocator, candidates: []const IEvictionCandidate, context: IRetentionContext) ![]const []const u8 {
        var freeBytes = context.deviceFreeBytes;
        if (freeBytes >= self.requiredFreeBytes) {
            return &.{};
        }

        var selected: std.ArrayList([]const u8) = .empty;
        for (try evictableOldestFirst(allocator, candidates)) |candidate| {
            if (freeBytes >= self.requiredFreeBytes) {
                break;
            }
            try selected.append(allocator, candidate.assetId);
            freeBytes += candidate.originalSizeBytes;
        }
        return selected.items;
    }
};

//
// Keeps no local originals at all beyond what the remote does not have. The smallest possible local
// database, at the cost of fetching an original from the remote every time one is wanted.
//
pub const DropWhenConfirmedRetentionPolicy = struct {
    //
    // Drops every confirmed original.
    //
    pub fn selectForEviction(self: DropWhenConfirmedRetentionPolicy, allocator: std.mem.Allocator, candidates: []const IEvictionCandidate, context: IRetentionContext) ![]const []const u8 {
        _ = self;
        _ = context;
        var selected: std.ArrayList([]const u8) = .empty;
        for (try evictableOldestFirst(allocator, candidates)) |candidate| {
            try selected.append(allocator, candidate.assetId);
        }
        return selected.items;
    }
};

//
// Chooses which local originals to drop. Each of the four policies is a variant of this union.
//
pub const RetentionPolicy = union(enum) {
    // Keeps the local originals under a byte cap.
    sizeBudget: SizeBudgetRetentionPolicy,

    // Keeps only recent local originals.
    recentDays: RecentDaysRetentionPolicy,

    // Keeps the device from filling up.
    freeSpace: FreeSpaceRetentionPolicy,

    // Drops every confirmed original.
    dropWhenConfirmed: DropWhenConfirmedRetentionPolicy,

    //
    // Returns the asset ids whose local original should be dropped, most preferred first.
    //
    pub fn selectForEviction(self: RetentionPolicy, allocator: std.mem.Allocator, candidates: []const IEvictionCandidate, context: IRetentionContext) ![]const []const u8 {
        return switch (self) {
            .sizeBudget => |policy| policy.selectForEviction(allocator, candidates, context),
            .recentDays => |policy| policy.selectForEviction(allocator, candidates, context),
            .freeSpace => |policy| policy.selectForEviction(allocator, candidates, context),
            .dropWhenConfirmed => |policy| policy.selectForEviction(allocator, candidates, context),
        };
    }
};

//
// Two gigabytes, the cap the size budget policy uses below.
//
const DEFAULT_LOCAL_ORIGINAL_BUDGET_BYTES: f64 = 2 * 1024 * 1024 * 1024;

//
// The policy the eviction task uses.
//
// Switching policy is uncommenting one of the lines below and commenting out this one. All four are
// implemented and tested, so none of them is a stub waiting to be finished.
//
pub const ACTIVE_RETENTION_POLICY: RetentionPolicy = .{
    .sizeBudget = .{
        .budgetBytes = DEFAULT_LOCAL_ORIGINAL_BUDGET_BYTES,
    },
};
// pub const ACTIVE_RETENTION_POLICY: RetentionPolicy = .{
//     .recentDays = .{
//         .days = 30,
//     },
// };
// pub const ACTIVE_RETENTION_POLICY: RetentionPolicy = .{
//     .freeSpace = .{
//         .requiredFreeBytes = 5 * 1024 * 1024 * 1024,
//     },
// };
// pub const ACTIVE_RETENTION_POLICY: RetentionPolicy = .{
//     .dropWhenConfirmed = .{},
// };
