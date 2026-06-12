import { formatCoordinates, formatDegreesMinutes } from "../../lib/coordinates";

describe("formatCoordinates", () => {

    test("formats northern and western coordinates", () => {
        expect(formatCoordinates({ lat: 32.306417, lng: -122.614583 })).toBe("32° 18.385' N 122° 36.875' W");
    });

    test("formats southern and eastern coordinates", () => {
        expect(formatCoordinates({ lat: -33.865, lng: 151.2094 })).toBe("33° 51.900' S 151° 12.564' E");
    });

    test("treats zero as the positive hemisphere", () => {
        expect(formatCoordinates({ lat: 0, lng: 0 })).toBe("0° 0.000' N 0° 0.000' E");
    });

    test("formats whole-degree values with zero minutes", () => {
        expect(formatCoordinates({ lat: 45, lng: -90 })).toBe("45° 0.000' N 90° 0.000' W");
    });

    test("rolls minutes over to the next degree when rounding reaches sixty", () => {
        expect(formatCoordinates({ lat: 10.99999999, lng: 20 })).toBe("11° 0.000' N 20° 0.000' E");
    });
});

describe("formatDegreesMinutes", () => {

    test("uses the positive hemisphere for positive values", () => {
        expect(formatDegreesMinutes(32.306417, "N", "S")).toBe("32° 18.385' N");
    });

    test("uses the negative hemisphere for negative values", () => {
        expect(formatDegreesMinutes(-122.614583, "E", "W")).toBe("122° 36.875' W");
    });

    test("uses the positive hemisphere for zero", () => {
        expect(formatDegreesMinutes(0, "N", "S")).toBe("0° 0.000' N");
    });

    test("formats a whole-degree value with zero minutes", () => {
        expect(formatDegreesMinutes(45, "N", "S")).toBe("45° 0.000' N");
    });

    test("rolls minutes over to the next degree when rounding reaches sixty", () => {
        expect(formatDegreesMinutes(10.99999999, "N", "S")).toBe("11° 0.000' N");
    });
});
