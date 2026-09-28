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

test "convert exif coordinates - with the other forms a JavaScript value can take" {
    // An int32 degree, a fraction without a denominator (NaN), and a fraction array whose denominator is
    // undefined (NaN) or null (0, so Infinity).
    const location = try reverse_geocode.convertExifCoordinates(TestDocument{
        .keys = &.{ "GPSLatitude", "GPSLongitude" },
        .values = &.{
            .{ .array = &.{ .{ .int32 = 12 }, .{ .number = 0 }, .{ .number = 0 } } },
            .{ .array = &.{ .{ .array = &.{ .{ .number = 1 }, .null } }, .{ .number = 0 }, .{ .number = 0 } } },
        },
    });
    try std.testing.expectEqual(@as(f64, 12), location.lat);
    try std.testing.expect(std.math.isPositiveInf(location.lng));

    const halfFraction = try reverse_geocode.convertExifCoordinates(TestDocument{
        .keys = &.{ "GPSLatitude", "GPSLongitude" },
        .values = &.{
            .{ .array = &.{ .{ .number = 10 }, .{ .number = 0 }, .{ .number = 0 } } },
            .{ .array = &.{ .{ .document = .{ .keys = &.{"numerator"}, .values = &.{.{ .number = 1 }} } }, .{ .number = 0 }, .{ .number = 0 } } },
        },
    });
    try std.testing.expectEqual(@as(f64, 10), halfFraction.lat);
    try std.testing.expect(std.math.isNan(halfFraction.lng));

    const undefinedDenominator = try reverse_geocode.convertExifCoordinates(TestDocument{
        .keys = &.{ "GPSLatitude", "GPSLongitude" },
        .values = &.{
            .{ .array = &.{ .{ .array = &.{ .{ .number = 1 }, .undefined } }, .{ .number = 0 }, .{ .number = 0 } } },
            .{ .array = &.{ .{ .number = 1 }, .{ .number = 0 }, .{ .number = 0 } } },
        },
    });
    try std.testing.expect(std.math.isNan(undefinedDenominator.lat));
}

test "convert exif coordinates - throws for values JavaScript cannot convert" {
    // A missing tag, a tag that is not an array and a null component throw a TypeError, like JavaScript.
    try std.testing.expectError(error.TypeError, reverse_geocode.convertExifCoordinates(TestDocument{ .keys = &.{}, .values = &.{} }));
    try std.testing.expectError(error.TypeError, reverse_geocode.convertExifCoordinates(TestDocument{
        .keys = &.{ "GPSLatitude", "GPSLongitude" },
        .values = &.{ .{ .number = 1 }, .{ .number = 1 } },
    }));
    try std.testing.expectError(error.TypeError, reverse_geocode.convertExifCoordinates(TestDocument{
        .keys = &.{ "GPSLatitude", "GPSLongitude" },
        .values = &.{ .{ .array = &.{.null} }, .{ .array = &.{} } },
    }));

    // A string or a boolean component is not ported.
    try std.testing.expectError(error.UnsupportedCoordinate, reverse_geocode.convertExifCoordinates(TestDocument{
        .keys = &.{ "GPSLatitude", "GPSLongitude" },
        .values = &.{ .{ .array = &.{.{ .string = "1" }} }, .{ .array = &.{} } },
    }));
    try std.testing.expectError(error.UnsupportedCoordinate, reverse_geocode.convertExifCoordinates(TestDocument{
        .keys = &.{ "GPSLatitude", "GPSLongitude" },
        .values = &.{ .{ .array = &.{.{ .array = &.{ .{ .number = 1 }, .{ .boolean = true } } }} }, .{ .array = &.{} } },
    }));
}

test "chooseBestResult prefers a premise to any other result, and skips results that are not objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const results = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\[
        \\  "not an object",
        \\  {"types":"not an array"},
        \\  {"types":["locality"],"address_components":[{"types":["locality"],"long_name":"Town"}]},
        \\  {"types":["premise"],"address_components":[
        \\    {"types":["premise"],"long_name":"Hall"},
        \\    {"types":["sublocality_level_1"],"long_name":"Ward"},
        \\    {"types":["locality"],"long_name":7},
        \\    {"types":["country"],"long_name":"Land"}
        \\  ]}
        \\]
    , .{});
    const best = try reverse_geocode.chooseBestResult(allocator, results);
    try std.testing.expectEqualStrings("premise", best.type);
    try std.testing.expectEqualStrings("Ward, Land", best.location);

    // The first result is taken when no result has a preferred type, and one that is not an object throws.
    try std.testing.expectError(error.TypeError, reverse_geocode.chooseBestResult(allocator, .{ .array = .{ .items = results.array.items[0..1], .capacity = 1, .allocator = allocator } }));
    try std.testing.expectError(error.TypeError, reverse_geocode.parseReverseGeocodeResult(allocator, results.array.items[1]));
}

//
// A local HTTP server standing in for the Google geocoding API: it answers one request with a status and body, and
// keeps the target of the request.
//
const GeocodeServer = struct {
    // The io the server runs on.
    io: std.Io,

    // The listening socket.
    server: std.Io.net.Server,

    // The port.
    port: u16,

    // Runs the one connection the server answers.
    group: std.Io.Group,

    // The status of the response.
    status: std.http.Status,

    // The body of the response.
    body: []const u8,

    // The target of the request received.
    target: [256]u8,

    // The length of the target received.
    targetLength: usize,

    //
    // Starts the server.
    //
    fn start(self: *GeocodeServer, io: std.Io, status: std.http.Status, body: []const u8) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{ .io = io, .server = try address.listen(io, .{ .reuse_address = true }), .port = 0, .group = .init, .status = status, .body = body, .target = undefined, .targetLength = 0 };
        self.port = self.server.socket.address.getPort();
        try self.group.concurrent(io, serveOne, .{self});
    }

    //
    // Stops the server once it has answered its one request.
    //
    fn stop(self: *GeocodeServer) void {
        self.group.await(self.io) catch {};
        self.server.deinit(self.io);
    }

    //
    // Accepts one connection and answers its request.
    //
    fn serveOne(self: *GeocodeServer) void {
        const stream = self.server.accept(self.io) catch {
            return;
        };
        defer stream.close(self.io);
        var receiveBuffer: [4096]u8 = undefined;
        var sendBuffer: [4096]u8 = undefined;
        var connectionReader = stream.reader(self.io, &receiveBuffer);
        var connectionWriter = stream.writer(self.io, &sendBuffer);
        var httpServer = std.http.Server.init(&connectionReader.interface, &connectionWriter.interface);
        var request = httpServer.receiveHead() catch {
            return;
        };
        self.targetLength = @min(request.head.target.len, self.target.len);
        @memcpy(self.target[0..self.targetLength], request.head.target[0..self.targetLength]);
        request.respond(self.body, .{ .status = self.status, .keep_alive = false }) catch {};
    }
};

//
// Reverse geocodes (1.5, -2) against a local server that answers with the status and body, and returns the result
// and the target of the request.
//
fn reverseGeocodeServed(allocator: std.mem.Allocator, server: *GeocodeServer, status: std.http.Status, body: []const u8) !?reverse_geocode.IReverseGeocodeResult {
    try server.start(std.testing.io, status, body);
    defer server.stop();
    const apiUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/geocode/json", .{server.port});
    return reverse_geocode.reverseGeocodeAt(allocator, std.testing.io, .{ .lat = 1.5, .lng = -2 }, "the-key", apiUrl);
}

test "reverse geocoding asks the API for the location and chooses the best result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server: GeocodeServer = undefined;
    const result = (try reverseGeocodeServed(arena.allocator(), &server, .ok,
        \\{"status":"OK","results":[{"types":["street_address"],"address_components":[
        \\  {"types":["street_number"],"long_name":"1"},{"types":["route"],"long_name":"Main Rd"}]}]}
    )).?;
    try std.testing.expectEqualStrings("/geocode/json?latlng=1.5,-2&key=the-key", server.target[0..server.targetLength]);
    try std.testing.expectEqualStrings("street_address", result.type);
    try std.testing.expectEqualStrings("1 Main Rd", result.location);
    try std.testing.expectEqual(@as(usize, 1), result.fullResult.array.items.len);
}

test "reverse geocoding throws the API's message when the request is denied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server: GeocodeServer = undefined;
    try std.testing.expectError(error.Thrown, reverseGeocodeServed(arena.allocator(), &server, .ok, "{\"status\":\"REQUEST_DENIED\",\"error_message\":\"The key is bad.\"}"));
    try std.testing.expectEqualStrings("Reverse geocoding failed: The key is bad.", utils.errors.lastErrorMessage());

    var serverWithoutMessage: GeocodeServer = undefined;
    try std.testing.expectError(error.Thrown, reverseGeocodeServed(arena.allocator(), &serverWithoutMessage, .ok, "{\"status\":\"REQUEST_DENIED\"}"));
    try std.testing.expectEqualStrings("Reverse geocoding failed: undefined", utils.errors.lastErrorMessage());
}

test "reverse geocoding gives nothing when the API finds nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var emptyServer: GeocodeServer = undefined;
    try std.testing.expect((try reverseGeocodeServed(arena.allocator(), &emptyServer, .ok, "{\"status\":\"ZERO_RESULTS\",\"results\":[]}")) == null);
    var missingServer: GeocodeServer = undefined;
    try std.testing.expect((try reverseGeocodeServed(arena.allocator(), &missingServer, .ok, "{\"status\":\"ZERO_RESULTS\"}")) == null);
    var arrayServer: GeocodeServer = undefined;
    try std.testing.expect((try reverseGeocodeServed(arena.allocator(), &arrayServer, .ok, "[1, 2]")) == null);

    // `response.data.status` of null throws, like JavaScript.
    var nullServer: GeocodeServer = undefined;
    try std.testing.expectError(error.Thrown, reverseGeocodeServed(arena.allocator(), &nullServer, .ok, "null"));
    try std.testing.expectEqualStrings("TypeError: Cannot read properties of null (reading 'status')", utils.errors.lastErrorMessage());
}

test "reverse geocoding throws when the API answers with an error status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server: GeocodeServer = undefined;
    try std.testing.expectError(error.Thrown, reverseGeocodeServed(arena.allocator(), &server, .internal_server_error, "{}"));
    try std.testing.expectEqualStrings("Request failed with status code 500", utils.errors.lastErrorMessage());
}
