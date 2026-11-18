import {
    RECENT_ARRIVAL_MS,
    isRecentArrival,
    markRecentArrival,
} from "../../lib/recent-arrivals";

//
// The arrivals are kept in one map for the whole module, so each test uses asset ids no other test
// uses, which keeps what one test marks out of every other test.
//
describe("recent arrivals", () => {

    const nowMs = 1000000;

    test("a photo that has not arrived is not recent", () => {
        expect(isRecentArrival("never-arrived", nowMs)).toBe(false);
    });

    test("a photo that has just arrived is recent", () => {
        markRecentArrival("just-arrived", nowMs);

        expect(isRecentArrival("just-arrived", nowMs)).toBe(true);
    });

    test("a photo is still recent just before the window closes", () => {
        markRecentArrival("window-edge", nowMs);

        expect(isRecentArrival("window-edge", nowMs + RECENT_ARRIVAL_MS)).toBe(true);
    });

    test("a photo stops being recent once the window has passed", () => {
        markRecentArrival("window-passed", nowMs);

        expect(isRecentArrival("window-passed", nowMs + RECENT_ARRIVAL_MS + 1)).toBe(false);
    });

    test("an expired arrival is forgotten rather than kept forever", () => {
        markRecentArrival("expired", nowMs);
        isRecentArrival("expired", nowMs + RECENT_ARRIVAL_MS + 1);

        // Asking again at the original time still says no: the record has gone, so a clock that
        // jumps backwards cannot bring an old arrival back to life.
        expect(isRecentArrival("expired", nowMs)).toBe(false);
    });

    test("one photo arriving says nothing about another", () => {
        markRecentArrival("arrived-alone", nowMs);

        expect(isRecentArrival("other-photo", nowMs)).toBe(false);
    });

    test("several photos can be recent at once", () => {
        markRecentArrival("several-1", nowMs);
        markRecentArrival("several-2", nowMs + 10);

        expect(isRecentArrival("several-1", nowMs + 20)).toBe(true);
        expect(isRecentArrival("several-2", nowMs + 20)).toBe(true);
    });

    test("arriving again restarts the window", () => {
        markRecentArrival("arrived-twice", nowMs);
        markRecentArrival("arrived-twice", nowMs + RECENT_ARRIVAL_MS);

        expect(isRecentArrival("arrived-twice", nowMs + RECENT_ARRIVAL_MS + 10)).toBe(true);
    });
});
