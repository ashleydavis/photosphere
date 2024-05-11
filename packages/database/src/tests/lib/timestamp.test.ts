import { createReverseChronoTimestamp } from "../../lib/timestamp";

describe('timestamp', () => {

    test('can create reverse chrono timestamp', () => {
        const currentDate = new Date("2021-01-01T00:00:00Z");
        expect(createReverseChronoTimestamp(currentDate)).toBe("00000030894220800000");
    });

    test('timestamp at target date is zero', () => {
        const targetDate = new Date("3000-01-01T00:00:00Z");
        expect(createReverseChronoTimestamp(targetDate)).toBe("00000000000000000000");
    });
});