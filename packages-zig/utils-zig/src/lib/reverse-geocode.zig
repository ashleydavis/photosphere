const std = @import("std");
const errors = @import("errors.zig");
const console = @import("console.zig");

//
// https://developers.google.com/maps/documentation/javascript
//
// Setup up project: https://developers.google.com/maps/documentation/javascript/cloud-setup
// Using API keys: https://developers.google.com/maps/documentation/javascript/get-api-key
// Reverse geocoding: https://developers.google.com/maps/documentation/javascript/examples/geocoding-reverse
// Had to wait 10 mins for the API key to come online: https://stackoverflow.com/a/27463276/25868
// I had to enable Maps, Places and Geocoding APIs to get the key to work.
//
// https://github.com/zhso/reverse-geocoding/blob/6ab209acd2c4d32438c947ecbd5bf4d50f4c5b8d/src/index.js#L18
//

pub const LAT_MIN: f64 = -90;
pub const LAT_MAX: f64 = 90;
pub const LNG_MIN: f64 = -180;
pub const LNG_MAX: f64 = 180;

//
// Represents a GPS location.
//
pub const ILocation = struct {
    // The latitude.
    lat: f64,

    // The longitude.
    lng: f64,
};

//
// Converts a component of a GPS coordinate to a number: a regular number, a fraction object
// (`{ numerator, denominator }`) or a `[numerator, denominator]` array. The value is a JavaScript value
// (serialization-zig's BsonValue, taken by duck typing because utils cannot depend on serialization).
//
fn convertNumber(value: anytype) !f64 {
    switch (value) {
        .array => |items| {
            // Convert fraction to a regular number.
            return try numberOf(if (items.len > 0) items[0] else null) / try numberOf(if (items.len > 1) items[1] else null);
        },
        .document => |fraction| {
            const numerator = fraction.get("numerator");
            const denominator = fraction.get("denominator");
            if (numerator != null and numerator.? != .undefined and denominator != null and denominator.? != .undefined) {
                return try numberOf(numerator) / try numberOf(denominator); // Convert fraction to a regular number.
            }
            return std.math.nan(f64);
        },
        .number, .double => |number| return number, // It is just a regular number.
        .int32 => |number| return @floatFromInt(number),
        // `fraction.numerator` of undefined or null throws a TypeError.
        .undefined, .null => return error.TypeError,
        // Not ported: a string or a boolean component (JavaScript would concatenate or add it).
        else => return error.UnsupportedCoordinate,
    }
}

//
// The number a JavaScript value holds, as division in convertNumber reads it (`undefined` is NaN).
//
fn numberOf(value: anytype) !f64 {
    const actual = value orelse return std.math.nan(f64);
    return switch (actual) {
        .number, .double => |number| number,
        .int32 => |number| @floatFromInt(number),
        .undefined => std.math.nan(f64),
        .null => 0,
        else => error.UnsupportedCoordinate,
    };
}

//
// Converts degress, minutes, seconds to degrees.
//
fn convertToDegrees(value: anytype) !f64 {
    const parts = switch (value) {
        .array => |items| items,
        // Destructuring a value that is not iterable throws a TypeError.
        else => return error.TypeError,
    };
    const deg = try convertNumber(if (parts.len > 0) parts[0] else .undefined);
    const min = try convertNumber(if (parts.len > 1) parts[1] else .undefined);
    const sec = try convertNumber(if (parts.len > 2) parts[2] else .undefined);
    return deg + (min / 60) + (sec / 3600);
}

//
// Checks if the location is in range.
//
pub fn isLocationInRange(location: ILocation) bool {
    return location.lat >= LAT_MIN and location.lat <= LAT_MAX and location.lng >= LNG_MIN and location.lng <= LNG_MAX;
}

//
// Converts exif coordinates to a location. The EXIF tags are a JavaScript object (serialization-zig's
// BsonDocument, taken by duck typing: `exif.get(name)` returns the value of a tag).
//
// https://gis.stackexchange.com/a/273402
//
pub fn convertExifCoordinates(exif: anytype) !ILocation {

    var coordinates: ILocation = .{
        .lat = try convertToDegrees(exif.get("GPSLatitude") orelse return error.TypeError),
        .lng = try convertToDegrees(exif.get("GPSLongitude") orelse return error.TypeError),
    };

    if (isString(exif.get("GPSLatitudeRef"), "S")) {
        // If the latitude reference is "S", the latitude is negative
        coordinates.lat = coordinates.lat * -1;
    }

    if (isString(exif.get("GPSLongitudeRef"), "W")) {
        // If the longitude reference is "W", the longitude is negative (thanks ChatGPT!)
        coordinates.lng = coordinates.lng * -1;
    }

    return coordinates;
}

//
// True when a JavaScript value is the given string (`value === text`).
//
fn isString(value: anytype, text: []const u8) bool {
    const actual = value orelse return false;
    return switch (actual) {
        .string => |string| std.mem.eql(u8, string, text),
        else => false,
    };
}

//
// Writes a coordinate like a template string does (`${coordinate}`).
//
fn formatCoordinate(allocator: std.mem.Allocator, coordinate: f64) ![]const u8 {
    if (std.math.isNan(coordinate)) {
        return "NaN";
    }
    if (std.math.isInf(coordinate)) {
        return if (coordinate < 0) "-Infinity" else "Infinity";
    }
    return std.fmt.allocPrint(allocator, "{d}", .{coordinate});
}

//
// Checks if the passed in coordinate is valid number.
//
fn checkCoordinateOk(allocator: std.mem.Allocator, coordinate: f64, name: []const u8, min: f64, max: f64) !void {
    if (std.math.isNan(coordinate) or !std.math.isFinite(coordinate)) {
        return errors.throwError("Bad \"{s}\" field: {s}", .{ name, try formatCoordinate(allocator, coordinate) });
    }

    if (coordinate < min) {
        return errors.throwError("Bad \"{s}\" field, value {s} is less than mininmum {d}", .{ name, try formatCoordinate(allocator, coordinate), min });
    }

    if (coordinate > max) {
        return errors.throwError("Bad \"{s}\" field, value {s} is more than maximum {d}", .{ name, try formatCoordinate(allocator, coordinate), max });
    }
}

//
// The result of reverse geocoding.
//
pub const IReverseGeocodeResult = struct {
    //
    // The formatted location.
    //
    location: []const u8,

    //
    // The selected type.
    //
    type: []const u8,

    //
    // Array of results from the reverse geocoder.
    //
    fullResult: std.json.Value,
};

//
// True when a result's `types` includes the type.
//
fn typesInclude(value: std.json.Value, desiredType: []const u8) bool {
    const types = switch (value) {
        .object => |object| object.get("types") orelse return false,
        else => return false,
    };
    const items = switch (types) {
        .array => |array| array.items,
        else => return false,
    };
    for (items) |item| {
        switch (item) {
            .string => |text| {
                if (std.mem.eql(u8, text, desiredType)) {
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

//
// Get the first result of reverse geocoding that matches the desired type.
//
pub fn getFirstResultOfType(results: []const std.json.Value, desiredType: []const u8) ?std.json.Value {
    for (results) |result| {
        if (typesInclude(result, desiredType)) {
            return result;
        }
    }
    return null;
}

//
// The address component fields, in the order they are read.
//
const fields = [_][]const []const u8{
    &.{"street_number"},
    &.{"route"},
    &.{"sublocality_level_2"},
    &.{"sublocality_level_1"},
    &.{ "locality", "administrative_area_level_2" },
    &.{"administrative_area_level_1"},
    &.{"country"},
};

//
// Parse a reverse geocode result.
//
pub fn parseReverseGeocodeResult(allocator: std.mem.Allocator, result: std.json.Value) ![]const u8 {

    // The value found for each field, by the index of the field in `fields` (TypeScript: `values[key]`).
    var values: [fields.len]?[]const u8 = [_]?[]const u8{null} ** fields.len;

    // `result.address_components` of a value that is not an object is undefined, which cannot be iterated.
    const resultObject = switch (result) {
        .object => |object| object,
        else => return error.TypeError,
    };
    const components = switch (resultObject.get("address_components") orelse return error.TypeError) {
        .array => |array| array.items,
        else => return error.TypeError,
    };
    for (components) |component| {
        for (fields, 0..) |fieldOptions, fieldIndex| {
            if (values[fieldIndex] != null and values[fieldIndex].?.len > 0) {
                continue;
            }

            for (fieldOptions) |fieldOption| {
                if (typesInclude(component, fieldOption)) {
                    values[fieldIndex] = switch (component.object.get("long_name") orelse .null) {
                        .string => |text| text,
                        else => null,
                    };
                    break;
                }
            }
        }
    }

    var streetAddress: ?[]const u8 = null;

    const streetNumber = values[0];
    const route = values[1];
    if (streetNumber != null and streetNumber.?.len > 0 and route != null and route.?.len > 0) {
        streetAddress = try std.fmt.allocPrint(allocator, "{s} {s}", .{ streetNumber.?, route.? });
    }

    var parts: std.ArrayList([]const u8) = .empty;

    if (streetAddress) |address| {
        try parts.append(allocator, address);
    }

    var alreadySet: std.StringHashMapUnmanaged(void) = .empty;

    for (values[2..]) |value| {
        if (value) |text| {
            if (text.len > 0) {
                if (alreadySet.contains(text)) {
                    continue;
                }
                try alreadySet.put(allocator, text, {});
                try parts.append(allocator, text);
            }
        }
    }

    return std.mem.join(allocator, ", ", parts.items);
}

//
// Choose the best result from the reverse geocoding.
//
pub fn chooseBestResult(allocator: std.mem.Allocator, results: std.json.Value) !IReverseGeocodeResult {
    const items = results.array.items;
    if (getFirstResultOfType(items, "street_address")) |firstStreetAddress| {
        return .{
            .location = try parseReverseGeocodeResult(allocator, firstStreetAddress),
            .type = "street_address",
            .fullResult = results,
        };
    }

    if (getFirstResultOfType(items, "premise")) |firstPremise| {
        return .{
            .location = try parseReverseGeocodeResult(allocator, firstPremise),
            .type = "premise",
            .fullResult = results,
        };
    }

    return .{
        .location = try parseReverseGeocodeResult(allocator, items[0]),
        .type = "any",
        .fullResult = results,
    };
}

//
// Sends a GET request for JSON (TypeScript: `axios.get(url, { headers: { Accept: "application/json" } })`), which
// rejects when the status is not 2xx. Returns the parsed body.
//
fn getJson(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !std.json.Value {
    var client: std.http.Client = .{ .allocator = std.heap.smp_allocator, .io = io };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(allocator);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
        .response_writer = &body.writer,
    });
    const status: u16 = @intFromEnum(result.status);
    if (status < 200 or status > 299) {
        return errors.throwError("Request failed with status code {d}", .{status});
    }
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, body.written(), .{});
}

//
// Reverse geocode the requested location (needs lat and lng fields).
//
// You must set an approriately configured Google API key in the environment variable GOOGLE_API_KEY for this to work.
//
pub fn reverseGeocode(allocator: std.mem.Allocator, io: std.Io, location: ILocation, googleApiKey: ?[]const u8) !?IReverseGeocodeResult {

    try checkCoordinateOk(allocator, location.lat, "lat", LAT_MIN, LAT_MAX);
    try checkCoordinateOk(allocator, location.lng, "lng", LNG_MIN, LNG_MAX);

    const apiKey = googleApiKey orelse "";
    if (apiKey.len == 0) {
        console.warn("No Google API key set. Not doing reverse geocoding.");
        return null;
    }

    //
    // Uncomment this code to fake an error in the reverse geocoder.
    //
    // throw new Error("Reverse geocoding - fake error.");

    const url = try std.fmt.allocPrint(allocator, "https://maps.googleapis.com/maps/api/geocode/json?latlng={s},{s}&key={s}", .{ try formatCoordinate(allocator, location.lat), try formatCoordinate(allocator, location.lng), apiKey });
    const data = try getJson(allocator, io, url);

    const dataObject = switch (data) {
        .object => |object| object,
        // `response.data.status` of null throws.
        .null => return errors.throwError("TypeError: Cannot read properties of null (reading 'status')", .{}),
        // Any other value has no status and no results.
        else => return null,
    };

    const status = dataObject.get("status");
    if (status != null and status.? == .string and std.mem.eql(u8, status.?.string, "REQUEST_DENIED")) {
        const errorMessage = dataObject.get("error_message");
        const message = if (errorMessage != null and errorMessage.? == .string) errorMessage.?.string else "undefined";
        return errors.throwError("Reverse geocoding failed: {s}", .{message});
    }

    if (dataObject.get("results")) |results| {
        if (results == .array and results.array.items.len > 0) {
            return try chooseBestResult(allocator, results);
        }
    }

    return null;
}
