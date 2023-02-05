import { convertExifCoordinates, reverseGeocode } from "../../lib/reverse-geocode";

describe("reverse geocoding", () => {

    const exifCoordinates = {
        GPSLatitudeRef: "N",
        GPSLatitude: [
            { numerator: 27, denominator: 1 },
            { numerator: 20, denominator: 1 },
            { numerator: 1183, denominator: 100 },
        ],
        GPSLongitudeRef: "E",
        GPSLongitude: [
            { numerator: 153, denominator: 1 },
            { numerator: 1, denominator: 1 },
            { numerator: 5312, denominator: 100 },
        ],
    };

    test("can convert exif coordinates to location", () => {
        const location = convertExifCoordinates(exifCoordinates);
        expect(location).toEqual({
            lat: 27.336619444444445,
            lng: 153.03142222222223,
        });
    });

    test("can convert exif coordinates to location - inverted", () => {
        const location = convertExifCoordinates({
            ...exifCoordinates,
            GPSLatitudeRef: "S",
            GPSLongitudeRef: "W",
        });
        expect(location).toEqual({
            lat: -27.336619444444445,
            lng: -153.03142222222223,
        });
    });
});