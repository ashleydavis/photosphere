import { dimensionsFromExif } from "../../lib/image";

//
// Covers reading a photo's size out of what the EXIF parser already read, which is what saves the
// import a second read of every photo just to ask how big it is.
//
describe("dimensionsFromExif", () => {

    test("a parse that found the frame header gives its size", () => {
        expect(dimensionsFromExif({ imageSize: { width: 4032, height: 3024 } })).toEqual({
            width: 4032,
            height: 3024,
        });
    });

    test("a parse that found no frame header gives nothing", () => {
        expect(dimensionsFromExif({ tags: {} })).toBeUndefined();
    });

    test("nothing parsed at all gives nothing", () => {
        expect(dimensionsFromExif(undefined)).toBeUndefined();
    });

    test("a size with a zero side is not a size", () => {
        expect(dimensionsFromExif({ imageSize: { width: 0, height: 3024 } })).toBeUndefined();
    });

    test("a negative side is not a size", () => {
        expect(dimensionsFromExif({ imageSize: { width: 4032, height: -1 } })).toBeUndefined();
    });

    test("a side that is not a whole number is not a size", () => {
        expect(dimensionsFromExif({ imageSize: { width: 4032.5, height: 3024 } })).toBeUndefined();
    });

    test("a side that is not a number at all is not a size", () => {
        expect(dimensionsFromExif({ imageSize: { width: "wide", height: 3024 } })).toBeUndefined();
    });
});
