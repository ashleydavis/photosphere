import { planOpenDatabase } from "../../lib/open-database-plan";

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
