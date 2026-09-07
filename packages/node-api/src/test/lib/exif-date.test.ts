import { parseExifDate, pickExifDate } from "../../lib/image";

//
// Which EXIF date a photo is given, and when it is given none.
//
// Nothing here touches the filesystem or a device, so it runs the same on Linux, macOS and Windows,
// and in the embedded JS engine on Android and iOS, which is where this runs during an import.
//

describe("parseExifDate", () => {

    test("reads the EXIF date format", () => {
        expect(parseExifDate("2025:03:27 20:22:57")).toBe("2025-03-27T20:22:57.000Z");
    });

    test("accepts a T in place of the space", () => {
        expect(parseExifDate("2025:03:27T20:22:57")).toBe("2025-03-27T20:22:57.000Z");
    });

    test("ignores anything after the seconds", () => {
        expect(parseExifDate("2025:03:27 20:22:57.123")).toBe("2025-03-27T20:22:57.000Z");
        expect(parseExifDate("2025:03:27 20:22:57+10:00")).toBe("2025-03-27T20:22:57.000Z");
    });

    test("ignores surrounding whitespace", () => {
        expect(parseExifDate("  2025:03:27 20:22:57\n")).toBe("2025-03-27T20:22:57.000Z");
    });

    test("reads the first and last moment of a day", () => {
        expect(parseExifDate("2024:01:01 00:00:00")).toBe("2024-01-01T00:00:00.000Z");
        expect(parseExifDate("2024:12:31 23:59:59")).toBe("2024-12-31T23:59:59.000Z");
    });

    test("reads a leap day", () => {
        expect(parseExifDate("2024:02:29 12:00:00")).toBe("2024-02-29T12:00:00.000Z");
    });

    test("refuses a value that is not a date", () => {
        expect(parseExifDate("not a date")).toBeUndefined();
        expect(parseExifDate("")).toBeUndefined();
        expect(parseExifDate("2025-03-27 20:22:57")).toBeUndefined();
        expect(parseExifDate("2025:03:27")).toBeUndefined();
    });

    test("refuses the all-zero date a camera writes when its clock was never set", () => {
        expect(parseExifDate("0000:00:00 00:00:00")).toBeUndefined();
    });

    test("refuses a date with a zero month or day", () => {
        expect(parseExifDate("2025:00:27 20:22:57")).toBeUndefined();
        expect(parseExifDate("2025:03:00 20:22:57")).toBeUndefined();
    });

    test("refuses a day that is not in its month", () => {
        expect(parseExifDate("2025:02:29 12:00:00")).toBeUndefined();
        expect(parseExifDate("2025:04:31 12:00:00")).toBeUndefined();
    });

    test("refuses an out of range month or time", () => {
        expect(parseExifDate("2025:13:01 12:00:00")).toBeUndefined();
        expect(parseExifDate("2025:03:27 24:00:00")).toBeUndefined();
        expect(parseExifDate("2025:03:27 20:60:00")).toBeUndefined();
        expect(parseExifDate("2025:03:27 20:22:60")).toBeUndefined();
    });

    test("refuses a value that is not a string", () => {
        expect(parseExifDate(undefined)).toBeUndefined();
        expect(parseExifDate(1743107777)).toBeUndefined();
        expect(parseExifDate([2025, 3, 27])).toBeUndefined();
    });
});

describe("pickExifDate reads a date that is in the metadata", () => {

    test("reads DateTimeOriginal", () => {
        expect(pickExifDate({ DateTimeOriginal: "2025:03:27 20:22:57" })).toBe("2025-03-27T20:22:57.000Z");
    });

    test("reads DateTimeDigitized", () => {
        expect(pickExifDate({ DateTimeDigitized: "2019:07:04 08:15:00" })).toBe("2019-07-04T08:15:00.000Z");
    });

    test("reads DateTime", () => {
        expect(pickExifDate({ DateTime: "2018:11:23 17:45:01" })).toBe("2018-11-23T17:45:01.000Z");
    });

    test("reads ModifyDate", () => {
        expect(pickExifDate({ ModifyDate: "2017:05:09 06:30:22" })).toBe("2017-05-09T06:30:22.000Z");
    });
});

describe("pickExifDate prefers the date the photo was taken", () => {

    test("DateTimeOriginal beats every other field", () => {
        const picked = pickExifDate({
            DateTime: "2025:03:31 12:40:49",
            DateTimeOriginal: "2025:03:27 20:22:57",
            DateTimeDigitized: "2025:03:28 09:00:00",
            ModifyDate: "2025:03:31 12:40:49",
        });
        expect(picked).toBe("2025-03-27T20:22:57.000Z");
    });

    test("DateTimeDigitized beats the modification fields", () => {
        const picked = pickExifDate({
            DateTime: "2025:03:31 12:40:49",
            DateTimeDigitized: "2025:03:28 09:00:00",
            ModifyDate: "2025:03:31 12:40:49",
        });
        expect(picked).toBe("2025-03-28T09:00:00.000Z");
    });

    test("a modification date is never taken over a capture date", () => {
        // Measured on a real photo from a phone library: the capture date is four days before the
        // modification date, and the photo was being filed under the later one.
        const picked = pickExifDate({
            DateTimeOriginal: "2025:03:27 20:22:57",
            ModifyDate: "2025:03:31 12:40:49",
        });
        expect(picked).toBe("2025-03-27T20:22:57.000Z");
    });

    test("skips a preferred field that holds no usable date", () => {
        const picked = pickExifDate({
            DateTimeOriginal: "0000:00:00 00:00:00",
            DateTimeDigitized: "2025:03:28 09:00:00",
        });
        expect(picked).toBe("2025-03-28T09:00:00.000Z");
    });
});

describe("pickExifDate reports no date when the metadata has none", () => {

    test("metadata with no date fields gives no date", () => {
        expect(pickExifDate({ Make: "Google", Model: "Pixel 6", Orientation: 1 })).toBeUndefined();
    });

    test("empty metadata gives no date", () => {
        expect(pickExifDate({})).toBeUndefined();
    });

    test("absent metadata gives no date", () => {
        expect(pickExifDate(undefined)).toBeUndefined();
    });

    test("date fields that are all unusable give no date", () => {
        const picked = pickExifDate({
            DateTimeOriginal: "0000:00:00 00:00:00",
            DateTime: "not a date",
            ModifyDate: "",
        });
        expect(picked).toBeUndefined();
    });
});
