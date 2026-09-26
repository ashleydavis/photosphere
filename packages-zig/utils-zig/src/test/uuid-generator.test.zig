const std = @import("std");
const utils = @import("utils-zig");

test "IUuidGenerator forwards generate to the implementation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: utils.test_uuid_generator.TestUuidGenerator = .{};
    const interface: utils.uuid_generator.IUuidGenerator = generator.uuidGenerator();
    const uuid = try interface.generate(arena.allocator(), std.testing.io);
    try std.testing.expectEqualStrings("93694f6e-3acb-4a1c-afd2-5fb8397575a5", uuid);
}
