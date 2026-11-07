import {
    RECENT_ARRIVAL_MS,
    clearRecentArrivals,
    isRecentArrival,
    markRecentArrival,
} from "../../lib/recent-arrivals";

describe("recent arrivals", () => {

    const nowMs = 1000000;

    beforeEach(() => {
        clearRecentArrivals();
    });

    test("a photo that has not arrived is not recent", () => {
        expect(isRecentArrival("asset-1", nowMs)).toBe(false);
    });

    test("a photo that has just arrived is recent", () => {
        markRecentArrival("asset-1", nowMs);

        expect(isRecentArrival("asset-1", nowMs)).toBe(true);
    });

    test("a photo is still recent just before the window closes", () => {
        markRecentArrival("asset-1", nowMs);

        expect(isRecentArrival("asset-1", nowMs + RECENT_ARRIVAL_MS)).toBe(true);
    });

    test("a photo stops being recent once the window has passed", () => {
        markRecentArrival("asset-1", nowMs);

        expect(isRecentArrival("asset-1", nowMs + RECENT_ARRIVAL_MS + 1)).toBe(false);
    });

    test("an expired arrival is forgotten rather than kept forever", () => {
        markRecentArrival("asset-1", nowMs);
        isRecentArrival("asset-1", nowMs + RECENT_ARRIVAL_MS + 1);

        // Asking again at the original time still says no: the record has gone, so a clock that
        // jumps backwards cannot bring an old arrival back to life.
        expect(isRecentArrival("asset-1", nowMs)).toBe(false);
    });

    test("one photo arriving says nothing about another", () => {
        markRecentArrival("asset-1", nowMs);

        expect(isRecentArrival("asset-2", nowMs)).toBe(false);
    });

    test("several photos can be recent at once", () => {
        markRecentArrival("asset-1", nowMs);
        markRecentArrival("asset-2", nowMs + 10);

        expect(isRecentArrival("asset-1", nowMs + 20)).toBe(true);
        expect(isRecentArrival("asset-2", nowMs + 20)).toBe(true);
    });

    test("arriving again restarts the window", () => {
        markRecentArrival("asset-1", nowMs);
        markRecentArrival("asset-1", nowMs + RECENT_ARRIVAL_MS);

        expect(isRecentArrival("asset-1", nowMs + RECENT_ARRIVAL_MS + 10)).toBe(true);
    });

    test("clearing forgets everything", () => {
        markRecentArrival("asset-1", nowMs);
        clearRecentArrivals();

        expect(isRecentArrival("asset-1", nowMs)).toBe(false);
    });
});
