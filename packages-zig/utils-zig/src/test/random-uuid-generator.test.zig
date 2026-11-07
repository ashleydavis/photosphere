const std = @import("std");
const utils = @import("utils-zig");
const RandomUuidGenerator = utils.random_uuid_generator.RandomUuidGenerator;

//
// Returns true when `uuid` is a lower case version 4 UUID string.
//
fn isUuidV4(uuid: []const u8) bool {
    if (uuid.len != 36) {
        return false;
    }
    for (uuid, 0..) |character, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (character != '-') {
                return false;
            }
        }
        else if (!std.ascii.isDigit(character) and !(character >= 'a' and character <= 'f')) {
            return false;
        }
    }
    const variant = uuid[19];
    return uuid[14] == '4' and (variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "generate() returns values in standard UUID v4 string format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: RandomUuidGenerator = .{};
    const uuid = try generator.uuidGenerator().generate(arena.allocator(), std.testing.io);
    try std.testing.expect(isUuidV4(uuid));
}

test "generate() returns unique values on successive calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: RandomUuidGenerator = .{};
    const first = try generator.generate(arena.allocator(), std.testing.io);
    const second = try generator.generate(arena.allocator(), std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}
