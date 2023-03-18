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

    test("convert exif coordinates - with normal numbers", () => {

        const location = convertExifCoordinates({
            GPSLatitudeRef: "N",
            GPSLatitude: [
                39,
                56,
                17.43
            ],
            GPSLongitudeRef: "E",
            GPSLongitude: [
                32,
                51,
                32.84
            ],
        });

        expect(location).toEqual({
            lat: 39.938174999999994,
            lng: 32.859122222222226,
        });
    });

    //
    // Tests reverse Geocoding with bad arguments.
    //
    async function testBadReverseGeocode(lat: any, lng: any, expectedMsg: string) {
        await expect(() => reverseGeocode({ 
                lat: lat,
                lng: lng,
            }))
            .rejects
            .toThrow(expectedMsg);
    }

    test("reverse geocoding throws with bad arguments", async () => {

        await testBadReverseGeocode(-27.346439781693057, undefined, `Bad "lng" field: undefined`);
        await testBadReverseGeocode(-27.346439781693057, null, `Bad "lng" field: null`);
        await testBadReverseGeocode(-27.346439781693057, 1/0, `Bad "lng" field: Infinity`);
        await testBadReverseGeocode(-27.346439781693057, parseInt("a"), `Bad "lng" field: NaN`);

        await testBadReverseGeocode(undefined, 153.0307858333819, `Bad "lat" field: undefined`);
        await testBadReverseGeocode(null, 153.0307858333819, `Bad "lat" field: null`);
        await testBadReverseGeocode(1/0, 153.0307858333819, `Bad "lat" field: Infinity`);
        await testBadReverseGeocode(parseInt("a"), 153.0307858333819, `Bad "lat" field: NaN`);

        await testBadReverseGeocode(-100, 10, `Bad "lat" field, value -100 is less than mininmum -90`);
        await testBadReverseGeocode(110, 10, `Bad "lat" field, value 110 is more than maximum 90`);

        await testBadReverseGeocode(10, -190, `Bad "lng" field, value -190 is less than mininmum -180`);
        await testBadReverseGeocode(10, 200, `Bad "lng" field, value 200 is more than maximum 180`);
    });

});