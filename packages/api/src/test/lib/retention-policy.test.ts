import {
    ACTIVE_RETENTION_POLICY,
    DropWhenConfirmedRetentionPolicy,
    FreeSpaceRetentionPolicy,
    IEvictionCandidate,
    IRetentionContext,
    IRetentionPolicy,
    RecentDaysRetentionPolicy,
    SizeBudgetRetentionPolicy,
} from "api";

const MEGABYTE = 1024 * 1024;
const GIGABYTE = 1024 * MEGABYTE;
const DAY_MS = 24 * 60 * 60 * 1000;
const NOW_MS = Date.parse("2026-06-01T00:00:00.000Z");

//
// A candidate for eviction. Confirmed on the origin unless the test says otherwise.
//
function candidate(assetId: string, overrides: Partial<IEvictionCandidate>): IEvictionCandidate {
    return {
        assetId,
        originalSizeBytes: MEGABYTE,
        importedAtMs: NOW_MS - DAY_MS,
        lastViewedAtMs: undefined,
        confirmedOnOrigin: true,
        ...overrides,
    };
}

//
// The context the policies read, with the totals a test cares about.
//
function context(overrides: Partial<IRetentionContext>): IRetentionContext {
    return {
        totalLocalOriginalBytes: 0,
        deviceFreeBytes: 100 * GIGABYTE,
        nowMs: NOW_MS,
        ...overrides,
    };
}

//
// A candidate imported the given number of days ago.
//
function importedDaysAgo(assetId: string, days: number, overrides: Partial<IEvictionCandidate>): IEvictionCandidate {
    return candidate(assetId, { importedAtMs: NOW_MS - (days * DAY_MS), ...overrides });
}

describe("SizeBudgetRetentionPolicy", () => {

    const policy = new SizeBudgetRetentionPolicy(10 * MEGABYTE);

    test("evicts nothing when the originals already fit", () => {
        const candidates = [candidate("a", {}), candidate("b", {})];
        expect(policy.selectForEviction(candidates, context({ totalLocalOriginalBytes: 2 * MEGABYTE }))).toEqual([]);
    });

    test("evicts nothing when the originals exactly fill the budget", () => {
        const candidates = [candidate("a", {})];
        expect(policy.selectForEviction(candidates, context({ totalLocalOriginalBytes: 10 * MEGABYTE }))).toEqual([]);
    });

    test("evicts the oldest first, and only as many as it takes", () => {
        const candidates = [
            importedDaysAgo("newest", 1, {}),
            importedDaysAgo("oldest", 100, {}),
            importedDaysAgo("middle", 50, {}),
        ];

        // Thirteen megabytes held, a ten megabyte budget: three megabytes have to go, which is three
        // one-megabyte originals.
        expect(policy.selectForEviction(candidates, context({ totalLocalOriginalBytes: 13 * MEGABYTE })))
            .toEqual(["oldest", "middle", "newest"]);
    });

    test("stops as soon as the remainder fits", () => {
        const candidates = [
            importedDaysAgo("oldest", 100, {}),
            importedDaysAgo("middle", 50, {}),
            importedDaysAgo("newest", 1, {}),
        ];

        expect(policy.selectForEviction(candidates, context({ totalLocalOriginalBytes: 11 * MEGABYTE })))
            .toEqual(["oldest"]);
    });

    test("counts the size of each original it drops", () => {
        const candidates = [
            importedDaysAgo("big", 100, { originalSizeBytes: 5 * MEGABYTE }),
            importedDaysAgo("small", 50, { originalSizeBytes: MEGABYTE }),
        ];

        expect(policy.selectForEviction(candidates, context({ totalLocalOriginalBytes: 14 * MEGABYTE })))
            .toEqual(["big"]);
    });

    test("evicts everything it can when that still is not enough", () => {
        const candidates = [importedDaysAgo("a", 3, {}), importedDaysAgo("b", 2, {})];

        expect(policy.selectForEviction(candidates, context({ totalLocalOriginalBytes: 100 * MEGABYTE })))
            .toEqual(["a", "b"]);
    });
});

describe("RecentDaysRetentionPolicy", () => {

    const policy = new RecentDaysRetentionPolicy(30);

    test("keeps originals inside the window", () => {
        const candidates = [importedDaysAgo("recent", 1, {}), importedDaysAgo("also-recent", 29, {})];
        expect(policy.selectForEviction(candidates, context({}))).toEqual([]);
    });

    test("evicts originals outside the window, oldest first", () => {
        const candidates = [
            importedDaysAgo("old", 31, {}),
            importedDaysAgo("recent", 1, {}),
            importedDaysAgo("ancient", 400, {}),
        ];

        expect(policy.selectForEviction(candidates, context({}))).toEqual(["ancient", "old"]);
    });

    test("an original exactly on the boundary is kept", () => {
        const candidates = [importedDaysAgo("boundary", 30, {})];
        expect(policy.selectForEviction(candidates, context({}))).toEqual([]);
    });

    test("evicts nothing from an empty library", () => {
        expect(policy.selectForEviction([], context({}))).toEqual([]);
    });
});

describe("FreeSpaceRetentionPolicy", () => {

    const policy = new FreeSpaceRetentionPolicy(10 * MEGABYTE);

    test("evicts nothing when there is already enough free space", () => {
        const candidates = [candidate("a", {})];
        expect(policy.selectForEviction(candidates, context({ deviceFreeBytes: 20 * MEGABYTE }))).toEqual([]);
    });

    test("evicts nothing when free space is exactly at the threshold", () => {
        const candidates = [candidate("a", {})];
        expect(policy.selectForEviction(candidates, context({ deviceFreeBytes: 10 * MEGABYTE }))).toEqual([]);
    });

    test("evicts the oldest until there is enough room", () => {
        const candidates = [
            importedDaysAgo("newest", 1, {}),
            importedDaysAgo("oldest", 100, {}),
            importedDaysAgo("middle", 50, {}),
        ];

        // Seven megabytes free, ten needed: three one-megabyte originals.
        expect(policy.selectForEviction(candidates, context({ deviceFreeBytes: 7 * MEGABYTE })))
            .toEqual(["oldest", "middle", "newest"]);
    });

    test("counts the size of each original it frees", () => {
        const candidates = [importedDaysAgo("big", 100, { originalSizeBytes: 8 * MEGABYTE })];

        expect(policy.selectForEviction(candidates, context({ deviceFreeBytes: 3 * MEGABYTE })))
            .toEqual(["big"]);
    });
});

describe("DropWhenConfirmedRetentionPolicy", () => {

    const policy = new DropWhenConfirmedRetentionPolicy();

    test("evicts every confirmed original", () => {
        const candidates = [importedDaysAgo("b", 1, {}), importedDaysAgo("a", 2, {})];
        expect(policy.selectForEviction(candidates, context({}))).toEqual(["a", "b"]);
    });

    test("evicts nothing from an empty library", () => {
        expect(policy.selectForEviction([], context({}))).toEqual([]);
    });
});

describe("every retention policy", () => {

    //
    // Every policy, each under conditions that make it want to evict as much as it can, so an
    // unconfirmed candidate slipping through would show up.
    //
    const policiesUnderPressure: { name: string, policy: IRetentionPolicy, context: IRetentionContext }[] = [
        {
            name: "SizeBudgetRetentionPolicy",
            policy: new SizeBudgetRetentionPolicy(0),
            context: context({ totalLocalOriginalBytes: 100 * GIGABYTE }),
        },
        {
            name: "RecentDaysRetentionPolicy",
            policy: new RecentDaysRetentionPolicy(0),
            context: context({}),
        },
        {
            name: "FreeSpaceRetentionPolicy",
            policy: new FreeSpaceRetentionPolicy(100 * GIGABYTE),
            context: context({ deviceFreeBytes: 0 }),
        },
        {
            name: "DropWhenConfirmedRetentionPolicy",
            policy: new DropWhenConfirmedRetentionPolicy(),
            context: context({}),
        },
    ];

    for (const { name, policy, context: policyContext } of policiesUnderPressure) {

        test(`${name} never evicts an original the origin does not hold`, () => {
            const candidates = [
                importedDaysAgo("not-on-origin", 500, { confirmedOnOrigin: false }),
                importedDaysAgo("on-origin", 400, { confirmedOnOrigin: true }),
            ];

            const selected = policy.selectForEviction(candidates, policyContext);

            expect(selected).not.toContain("not-on-origin");
            expect(selected).toContain("on-origin");
        });

        test(`${name} evicts nothing when nothing is confirmed`, () => {
            const candidates = [
                importedDaysAgo("a", 500, { confirmedOnOrigin: false }),
                importedDaysAgo("b", 400, { confirmedOnOrigin: false }),
            ];

            expect(policy.selectForEviction(candidates, policyContext)).toEqual([]);
        });
    }
});

describe("ACTIVE_RETENTION_POLICY", () => {

    test("is the two gigabyte size budget", () => {
        const candidates = [importedDaysAgo("old", 100, { originalSizeBytes: GIGABYTE })];

        // Under the cap, so nothing goes.
        expect(ACTIVE_RETENTION_POLICY.selectForEviction(candidates, context({ totalLocalOriginalBytes: 2 * GIGABYTE })))
            .toEqual([]);

        // Over the cap, so the oldest goes.
        expect(ACTIVE_RETENTION_POLICY.selectForEviction(candidates, context({ totalLocalOriginalBytes: 3 * GIGABYTE })))
            .toEqual(["old"]);
    });

    test("never evicts an original the origin does not hold", () => {
        const candidates = [importedDaysAgo("not-on-origin", 100, { originalSizeBytes: GIGABYTE, confirmedOnOrigin: false })];

        expect(ACTIVE_RETENTION_POLICY.selectForEviction(candidates, context({ totalLocalOriginalBytes: 100 * GIGABYTE })))
            .toEqual([]);
    });
});
