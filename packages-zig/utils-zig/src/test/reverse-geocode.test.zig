const std = @import("std");
const utils = @import("utils-zig");
const reverse_geocode = utils.reverse_geocode;

//
// A stand-in for a JavaScript value (serialization-zig's BsonValue, which utils reads by duck typing).
//
const TestValue = union(enum) {
    // A number.
    number: f64,

    // An int32.
    int32: i32,

    // A double.
    double: f64,

    // A string.
    string: []const u8,

    // An array.
    array: []const TestValue,

    // An object.
    document: TestDocument,

    // A boolean.
    boolean: bool,

    // null.
    null,

    // undefined.
    undefined,
};

//
// A stand-in for a JavaScript object.
//
const TestDocument = struct {
    // The keys.
    keys: []const []const u8,

    // The values, by the index of their key.
    values: []const TestValue,

    //
    // Gets a property.
    //
    pub fn get(self: TestDocument, key: []const u8) ?TestValue {
        for (self.keys, self.values) |candidate, value| {
            if (std.mem.eql(u8, candidate, key)) {
                return value;
            }
        }
        return null;
    }
};

//
// A `{ numerator, denominator }` fraction.
//
fn fraction(comptime numerator: f64, comptime denominator: f64) TestValue {
    return .{ .document = .{ .keys = &.{ "numerator", "denominator" }, .values = &.{ .{ .number = numerator }, .{ .number = denominator } } } };
}

//
// EXIF tags with the given references.
//
fn exifCoordinates(comptime latitudeRef: []const u8, comptime longitudeRef: []const u8) TestDocument {
    return .{
        .keys = &.{ "GPSLatitudeRef", "GPSLatitude", "GPSLongitudeRef", "GPSLongitude" },
        .values = &.{
            .{ .string = latitudeRef },
            .{ .array = &.{ fraction(27, 1), fraction(20, 1), fraction(1183, 100) } },
            .{ .string = longitudeRef },
            .{ .array = &.{ fraction(153, 1), fraction(1, 1), fraction(5312, 100) } },
        },
    };
}

test "can convert exif coordinates to location" {
    const location = try reverse_geocode.convertExifCoordinates(comptime exifCoordinates("N", "E"));
    try std.testing.expectEqual(@as(f64, 27.336619444444445), location.lat);
    try std.testing.expectEqual(@as(f64, 153.03142222222223), location.lng);
}

test "can convert exif coordinates to location - inverted" {
    const location = try reverse_geocode.convertExifCoordinates(comptime exifCoordinates("S", "W"));
    try std.testing.expectEqual(@as(f64, -27.336619444444445), location.lat);
    try std.testing.expectEqual(@as(f64, -153.03142222222223), location.lng);
}

test "convert exif coordinates - with normal numbers" {
    const location = try reverse_geocode.convertExifCoordinates(TestDocument{
        .keys = &.{ "GPSLatitudeRef", "GPSLatitude", "GPSLongitudeRef", "GPSLongitude" },
        .values = &.{
            .{ .string = "N" },
            .{ .array = &.{ .{ .number = 39 }, .{ .number = 56 }, .{ .number = 17.43 } } },
            .{ .string = "E" },
            .{ .array = &.{ .{ .number = 32 }, .{ .number = 51 }, .{ .number = 32.84 } } },
        },
    });
    try std.testing.expectEqual(@as(f64, 39.938174999999994), location.lat);
    try std.testing.expectEqual(@as(f64, 32.859122222222226), location.lng);
}

test "convert exif coordinates - with rationals as exif-parser reads them" {
    const location = try reverse_geocode.convertExifCoordinates(TestDocument{
        .keys = &.{ "GPSLatitudeRef", "GPSLatitude", "GPSLongitudeRef", "GPSLongitude" },
        .values = &.{
            .{ .string = "S" },
            .{ .array = &.{ .{ .array = &.{ .{ .number = 29 }, .{ .number = 1 } } }, .{ .array = &.{ .{ .number = 1 }, .{ .number = 1 } } }, .{ .array = &.{ .{ .number = 856 }, .{ .number = 100 } } } } },
            .{ .string = "E" },
            .{ .array = &.{ .{ .array = &.{ .{ .number = 153 }, .{ .number = 1 } } }, .{ .array = &.{ .{ .number = 0 }, .{ .number = 1 } } }, .{ .array = &.{ .{ .number = 0 }, .{ .number = 1 } } } } },
        },
    });
    try std.testing.expectEqual(@as(f64, -(29.0 + 1.0 / 60.0 + 8.56 / 3600.0)), location.lat);
    try std.testing.expectEqual(@as(f64, 153), location.lng);
}

//
// Tests reverse Geocoding with bad arguments.
//
fn testBadReverseGeocode(lat: f64, lng: f64, expectedMsg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, reverse_geocode.reverseGeocode(arena.allocator(), std.testing.io, .{ .lat = lat, .lng = lng }, "this doesn't matter in the test"));
    try std.testing.expectEqualStrings(expectedMsg, utils.errors.lastErrorMessage());
}

test "reverse geocoding throws with bad arguments" {
    // Not ported: undefined and null coordinates (ILocation holds numbers in Zig).
    try testBadReverseGeocode(-27.346439781693057, std.math.inf(f64), "Bad \"lng\" field: Infinity");
    try testBadReverseGeocode(-27.346439781693057, std.math.nan(f64), "Bad \"lng\" field: NaN");

    try testBadReverseGeocode(std.math.inf(f64), 153.0307858333819, "Bad \"lat\" field: Infinity");
    try testBadReverseGeocode(std.math.nan(f64), 153.0307858333819, "Bad \"lat\" field: NaN");

    try testBadReverseGeocode(-100, 10, "Bad \"lat\" field, value -100 is less than mininmum -90");
    try testBadReverseGeocode(110, 10, "Bad \"lat\" field, value 110 is more than maximum 90");

    try testBadReverseGeocode(10, -190, "Bad \"lng\" field, value -190 is less than mininmum -180");
    try testBadReverseGeocode(10, 200, "Bad \"lng\" field, value 200 is more than maximum 180");
}

test "reverse geocoding does nothing without an API key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try reverse_geocode.reverseGeocode(arena.allocator(), std.testing.io, .{ .lat = 1, .lng = 2 }, null)) == null);
}

test "isLocationInRange checks both coordinates" {
    try std.testing.expect(reverse_geocode.isLocationInRange(.{ .lat = -90, .lng = 180 }));
    try std.testing.expect(!reverse_geocode.isLocationInRange(.{ .lat = -90.1, .lng = 0 }));
    try std.testing.expect(!reverse_geocode.isLocationInRange(.{ .lat = 0, .lng = 180.5 }));
}

test "parseReverseGeocodeResult joins the address components and chooseBestResult prefers a street address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const results = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\[
        \\  {"types":["locality"],"address_components":[{"types":["locality"],"long_name":"Town"}]},
        \\  {"types":["street_address"],"address_components":[
        \\    {"types":["street_number"],"long_name":"12"},
        \\    {"types":["route"],"long_name":"High St"},
        \\    {"types":["locality"],"long_name":"Town"},
        \\    {"types":["administrative_area_level_2"],"long_name":"Shire"},
        \\    {"types":["administrative_area_level_1"],"long_name":"Town"},
        \\    {"types":["country"],"long_name":"Land"}
        \\  ]}
        \\]
    , .{});
    const best = try reverse_geocode.chooseBestResult(allocator, results);
    try std.testing.expectEqualStrings("street_address", best.type);
    try std.testing.expectEqualStrings("12 High St, Town, Land", best.location);

    const any = try reverse_geocode.chooseBestResult(allocator, .{ .array = .{ .items = results.array.items[0..1], .capacity = 1, .allocator = allocator } });
    try std.testing.expectEqualStrings("any", any.type);
    try std.testing.expectEqualStrings("Town", any.location);
}
