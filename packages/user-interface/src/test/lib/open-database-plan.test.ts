import { planLoadTeardown, planOpenDatabase } from "../../lib/open-database-plan";

describe("planOpenDatabase", () => {

    test("opening a database when none is open loads through the path change", () => {
        expect(planOpenDatabase({
            openDatabasePath: undefined,
            requestedDatabasePath: "s3:bucket/one",
            loadingDatabasePath: undefined,
        })).toEqual({
            closeFirst: false,
            startLoadDirectly: false,
        });
    });

    test("opening a different database closes the open one and loads through the path change", () => {
        expect(planOpenDatabase({
            openDatabasePath: "s3:bucket/one",
            requestedDatabasePath: "s3:bucket/two",
            loadingDatabasePath: undefined,
        })).toEqual({
            closeFirst: true,
            startLoadDirectly: false,
        });
    });

    test("opening a different database while the open one is still loading still closes it", () => {
        expect(planOpenDatabase({
            openDatabasePath: "s3:bucket/one",
            requestedDatabasePath: "s3:bucket/two",
            loadingDatabasePath: "s3:bucket/one",
        })).toEqual({
            closeFirst: true,
            startLoadDirectly: false,
        });
    });

    test("reopening the open database while its load is still running leaves it alone", () => {
        expect(planOpenDatabase({
            openDatabasePath: "s3:bucket/one",
            requestedDatabasePath: "s3:bucket/one",
            loadingDatabasePath: "s3:bucket/one",
        })).toEqual({
            closeFirst: false,
            startLoadDirectly: false,
        });
    });

    // The case that emptied the gallery on Release run 33455400870: the load was running when the
    // click landed and finished during the existence check, so by here there is no load to protect,
    // the close wipes the assets it had just loaded, and the path is about to be set to the value it
    // already holds. Nothing reloads unless this says so.
    test("reopening the open database after its load finished closes it and starts the load directly", () => {
        expect(planOpenDatabase({
            openDatabasePath: "s3:bucket/one",
            requestedDatabasePath: "s3:bucket/one",
            loadingDatabasePath: undefined,
        })).toEqual({
            closeFirst: true,
            startLoadDirectly: true,
        });
    });

    test("reopening the open database while a different database is loading closes it and starts the load directly", () => {
        expect(planOpenDatabase({
            openDatabasePath: "s3:bucket/one",
            requestedDatabasePath: "s3:bucket/one",
            loadingDatabasePath: "s3:bucket/two",
        })).toEqual({
            closeFirst: true,
            startLoadDirectly: true,
        });
    });
});

describe("planLoadTeardown", () => {

    test("the effect rendered with no database started no load to tear down", () => {
        expect(planLoadTeardown({
            startedLoadId: undefined,
            currentLoadId: undefined,
        })).toBe(false);
    });

    test("tears down the load the cleaned-up effect started", () => {
        expect(planLoadTeardown({
            startedLoadId: "load-1",
            currentLoadId: "load-1",
        })).toBe(true);
    });

    // A reopen of the same database closes it and starts the replacement load from openDatabase
    // before React renders the path back, so the load running at cleanup is that replacement. Both
    // loads are for the same database, which is why comparing database paths cannot tell them apart:
    // the cleanup cancelled the replacement and the effect started a second load, and both reported
    // 0 assets (smoke test 26). Comparing ids does tell them apart.
    test("leaves a replacement load alone, even though it is for the same database", () => {
        expect(planLoadTeardown({
            startedLoadId: "load-1",
            currentLoadId: "load-2",
        })).toBe(false);
    });

    test("nothing to tear down when no load is running any more", () => {
        expect(planLoadTeardown({
            startedLoadId: "load-1",
            currentLoadId: undefined,
        })).toBe(false);
    });
});
