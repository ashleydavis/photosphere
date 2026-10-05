//
// The root of the unit test program. It imports each test file, which a test file under src/test cannot be the root
// for because it imports the code beside it.
//

test {
    _ = @import("test/geometry.test.zig");
    _ = @import("test/accelerator.test.zig");
    _ = @import("test/actions.test.zig");
    _ = @import("test/menu.test.zig");
    _ = @import("test/pickers.test.zig");
}
