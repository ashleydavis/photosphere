const std = @import("std");
const api_zig = @import("api-zig");
const retention_policy = api_zig.retention_policy;
const IEvictionCandidate = retention_policy.IEvictionCandidate;
const IRetentionContext = retention_policy.IRetentionContext;
const RetentionPolicy = retention_policy.RetentionPolicy;

const MEGABYTE: f64 = 1024 * 1024;
const GIGABYTE: f64 = 1024 * MEGABYTE;
const DAY_MS: f64 = 24 * 60 * 60 * 1000;

// 2026-06-01T00:00:00.000Z in milliseconds since the epoch.
const NOW_MS: f64 = 1780272000000;

//
// A candidate for eviction. Confirmed on the origin unless the test says otherwise.
// Zig has no spread, so the overrides are the functions withSize and unconfirmed.
//
fn candidate(assetId: []const u8) IEvictionCandidate {
    return .{
        .assetId = assetId,
        .originalSizeBytes = MEGABYTE,
        .importedAtMs = NOW_MS - DAY_MS,
        .lastViewedAtMs = null,
        .confirmedOnOrigin = true,
    };
}

//
// A candidate imported the given number of days ago.
//
fn importedDaysAgo(assetId: []const u8, days: f64) IEvictionCandidate {
    var result = candidate(assetId);
    result.importedAtMs = NOW_MS - (days * DAY_MS);
    return result;
}

//
// The candidate with another original size.
//
fn withSize(original: IEvictionCandidate, originalSizeBytes: f64) IEvictionCandidate {
    var result = original;
    result.originalSizeBytes = originalSizeBytes;
    return result;
}

//
// The candidate that the origin does not hold.
//
fn unconfirmed(original: IEvictionCandidate) IEvictionCandidate {
    var result = original;
    result.confirmedOnOrigin = false;
    return result;
}

//
// The context the policies read, with the totals a test cares about.
//
fn context(totalLocalOriginalBytes: f64, deviceFreeBytes: f64) IRetentionContext {
    return .{
        .totalLocalOriginalBytes = totalLocalOriginalBytes,
        .deviceFreeBytes = deviceFreeBytes,
        .nowMs = NOW_MS,
    };
}

//
// The context of a test that cares about neither total.
//
fn defaultContext() IRetentionContext {
    return context(0, 100 * GIGABYTE);
}

//
// Selects with a policy in an arena of the test.
//
fn select(allocator: std.mem.Allocator, policy: RetentionPolicy, candidates: []const IEvictionCandidate, policyContext: IRetentionContext) ![]const []const u8 {
    return policy.selectForEviction(allocator, candidates, policyContext);
}

//
// Expects the selected ids to be the expected ones, in order.
//
fn expectIds(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedId, actualId| {
        try std.testing.expectEqualStrings(expectedId, actualId);
    }
}

//
// Whether the ids hold the given one.
//
fn contains(ids: []const []const u8, wanted: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, wanted)) {
            return true;
        }
    }
    return false;
}

const sizeBudgetPolicy: RetentionPolicy = .{
    .sizeBudget = .{
        .budgetBytes = 10 * MEGABYTE,
    },
};

test "SizeBudgetRetentionPolicy evicts nothing when the originals already fit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{ candidate("a"), candidate("b") };
    try expectIds(&.{}, try select(arena.allocator(), sizeBudgetPolicy, &candidates, context(2 * MEGABYTE, 100 * GIGABYTE)));
}

test "SizeBudgetRetentionPolicy evicts nothing when the originals exactly fill the budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{candidate("a")};
    try expectIds(&.{}, try select(arena.allocator(), sizeBudgetPolicy, &candidates, context(10 * MEGABYTE, 100 * GIGABYTE)));
}

test "SizeBudgetRetentionPolicy evicts the oldest first, and only as many as it takes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{
        importedDaysAgo("newest", 1),
        importedDaysAgo("oldest", 100),
        importedDaysAgo("middle", 50),
    };

    // Thirteen megabytes held, a ten megabyte budget: three megabytes have to go, which is three
    // one-megabyte originals.
    try expectIds(&.{ "oldest", "middle", "newest" }, try select(arena.allocator(), sizeBudgetPolicy, &candidates, context(13 * MEGABYTE, 100 * GIGABYTE)));
}

test "SizeBudgetRetentionPolicy stops as soon as the remainder fits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{
        importedDaysAgo("oldest", 100),
        importedDaysAgo("middle", 50),
        importedDaysAgo("newest", 1),
    };

    try expectIds(&.{"oldest"}, try select(arena.allocator(), sizeBudgetPolicy, &candidates, context(11 * MEGABYTE, 100 * GIGABYTE)));
}

test "SizeBudgetRetentionPolicy counts the size of each original it drops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{
        withSize(importedDaysAgo("big", 100), 5 * MEGABYTE),
        withSize(importedDaysAgo("small", 50), MEGABYTE),
    };

    try expectIds(&.{"big"}, try select(arena.allocator(), sizeBudgetPolicy, &candidates, context(14 * MEGABYTE, 100 * GIGABYTE)));
}

test "SizeBudgetRetentionPolicy evicts everything it can when that still is not enough" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{ importedDaysAgo("a", 3), importedDaysAgo("b", 2) };

    try expectIds(&.{ "a", "b" }, try select(arena.allocator(), sizeBudgetPolicy, &candidates, context(100 * MEGABYTE, 100 * GIGABYTE)));
}

const recentDaysPolicy: RetentionPolicy = .{
    .recentDays = .{
        .days = 30,
    },
};

test "RecentDaysRetentionPolicy keeps originals inside the window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{ importedDaysAgo("recent", 1), importedDaysAgo("also-recent", 29) };
    try expectIds(&.{}, try select(arena.allocator(), recentDaysPolicy, &candidates, defaultContext()));
}

test "RecentDaysRetentionPolicy evicts originals outside the window, oldest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{
        importedDaysAgo("old", 31),
        importedDaysAgo("recent", 1),
        importedDaysAgo("ancient", 400),
    };

    try expectIds(&.{ "ancient", "old" }, try select(arena.allocator(), recentDaysPolicy, &candidates, defaultContext()));
}

test "RecentDaysRetentionPolicy an original exactly on the boundary is kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{importedDaysAgo("boundary", 30)};
    try expectIds(&.{}, try select(arena.allocator(), recentDaysPolicy, &candidates, defaultContext()));
}

test "RecentDaysRetentionPolicy evicts nothing from an empty library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectIds(&.{}, try select(arena.allocator(), recentDaysPolicy, &.{}, defaultContext()));
}

const freeSpacePolicy: RetentionPolicy = .{
    .freeSpace = .{
        .requiredFreeBytes = 10 * MEGABYTE,
    },
};

test "FreeSpaceRetentionPolicy evicts nothing when there is already enough free space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{candidate("a")};
    try expectIds(&.{}, try select(arena.allocator(), freeSpacePolicy, &candidates, context(0, 20 * MEGABYTE)));
}

test "FreeSpaceRetentionPolicy evicts nothing when free space is exactly at the threshold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{candidate("a")};
    try expectIds(&.{}, try select(arena.allocator(), freeSpacePolicy, &candidates, context(0, 10 * MEGABYTE)));
}

test "FreeSpaceRetentionPolicy evicts the oldest until there is enough room" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{
        importedDaysAgo("newest", 1),
        importedDaysAgo("oldest", 100),
        importedDaysAgo("middle", 50),
    };

    // Seven megabytes free, ten needed: three one-megabyte originals.
    try expectIds(&.{ "oldest", "middle", "newest" }, try select(arena.allocator(), freeSpacePolicy, &candidates, context(0, 7 * MEGABYTE)));
}

test "FreeSpaceRetentionPolicy counts the size of each original it frees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{withSize(importedDaysAgo("big", 100), 8 * MEGABYTE)};

    try expectIds(&.{"big"}, try select(arena.allocator(), freeSpacePolicy, &candidates, context(0, 3 * MEGABYTE)));
}

const dropWhenConfirmedPolicy: RetentionPolicy = .{
    .dropWhenConfirmed = .{},
};

test "DropWhenConfirmedRetentionPolicy evicts every confirmed original" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{ importedDaysAgo("b", 1), importedDaysAgo("a", 2) };
    try expectIds(&.{ "a", "b" }, try select(arena.allocator(), dropWhenConfirmedPolicy, &candidates, defaultContext()));
}

test "DropWhenConfirmedRetentionPolicy evicts nothing from an empty library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectIds(&.{}, try select(arena.allocator(), dropWhenConfirmedPolicy, &.{}, defaultContext()));
}

//
// A policy under conditions that make it want to evict as much as it can, so an unconfirmed candidate slipping
// through would show up.
//
const PolicyUnderPressure = struct {
    // The name of the policy.
    name: []const u8,

    // The policy.
    policy: RetentionPolicy,

    // The context that makes it evict as much as it can.
    context: IRetentionContext,
};

//
// Every policy, each under conditions that make it want to evict as much as it can, so an
// unconfirmed candidate slipping through would show up.
//
fn policiesUnderPressure() [4]PolicyUnderPressure {
    return .{
        .{
            .name = "SizeBudgetRetentionPolicy",
            .policy = .{
                .sizeBudget = .{
                    .budgetBytes = 0,
                },
            },
            .context = context(100 * GIGABYTE, 100 * GIGABYTE),
        },
        .{
            .name = "RecentDaysRetentionPolicy",
            .policy = .{
                .recentDays = .{
                    .days = 0,
                },
            },
            .context = defaultContext(),
        },
        .{
            .name = "FreeSpaceRetentionPolicy",
            .policy = .{
                .freeSpace = .{
                    .requiredFreeBytes = 100 * GIGABYTE,
                },
            },
            .context = context(0, 0),
        },
        .{
            .name = "DropWhenConfirmedRetentionPolicy",
            .policy = .{
                .dropWhenConfirmed = .{},
            },
            .context = defaultContext(),
        },
    };
}

test "every retention policy never evicts an original the origin does not hold" {
    for (policiesUnderPressure()) |underPressure| {
        errdefer std.debug.print("policy: {s}\n", .{underPressure.name});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const candidates = [_]IEvictionCandidate{
            unconfirmed(importedDaysAgo("not-on-origin", 500)),
            importedDaysAgo("on-origin", 400),
        };

        const selected = try select(arena.allocator(), underPressure.policy, &candidates, underPressure.context);

        try std.testing.expect(!contains(selected, "not-on-origin"));
        try std.testing.expect(contains(selected, "on-origin"));
    }
}

test "every retention policy evicts nothing when nothing is confirmed" {
    for (policiesUnderPressure()) |underPressure| {
        errdefer std.debug.print("policy: {s}\n", .{underPressure.name});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const candidates = [_]IEvictionCandidate{
            unconfirmed(importedDaysAgo("a", 500)),
            unconfirmed(importedDaysAgo("b", 400)),
        };

        try expectIds(&.{}, try select(arena.allocator(), underPressure.policy, &candidates, underPressure.context));
    }
}

test "ACTIVE_RETENTION_POLICY is the two gigabyte size budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{withSize(importedDaysAgo("old", 100), GIGABYTE)};

    // Under the cap, so nothing goes.
    try expectIds(&.{}, try select(arena.allocator(), retention_policy.ACTIVE_RETENTION_POLICY, &candidates, context(2 * GIGABYTE, 100 * GIGABYTE)));

    // Over the cap, so the oldest goes.
    try expectIds(&.{"old"}, try select(arena.allocator(), retention_policy.ACTIVE_RETENTION_POLICY, &candidates, context(3 * GIGABYTE, 100 * GIGABYTE)));
}

test "ACTIVE_RETENTION_POLICY never evicts an original the origin does not hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{unconfirmed(withSize(importedDaysAgo("not-on-origin", 100), GIGABYTE))};

    try expectIds(&.{}, try select(arena.allocator(), retention_policy.ACTIVE_RETENTION_POLICY, &candidates, context(100 * GIGABYTE, 100 * GIGABYTE)));
}

test "candidates imported at the same moment are ordered by asset id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]IEvictionCandidate{ importedDaysAgo("b", 5), importedDaysAgo("c", 5), importedDaysAgo("a", 5) };
    try expectIds(&.{ "a", "b", "c" }, try select(arena.allocator(), dropWhenConfirmedPolicy, &candidates, defaultContext()));
}
