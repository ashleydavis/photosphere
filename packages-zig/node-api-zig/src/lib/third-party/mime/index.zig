//
// Port of mime 4.1.0 src/index.ts: the default Mime instance, knowing the standard and the other types.
//
// mime (c) 2023 Robert Kieffer, MIT license.
//

const std = @import("std");
const Mime = @import("Mime.zig").Mime;
const standardTypes = @import("types/standard.zig").types;
const otherTypes = @import("types/other.zig").types;

//
// Allocator for the default instance, which lives for the rest of the process.
//
const mime_allocator = std.heap.smp_allocator;

//
// The default instance (TypeScript: `new Mime(standardTypes, otherTypes)._freeze()`, built when the module loads;
// here it is built on first use).
//
var defaultMime: Mime = undefined;

//
// Whether the default instance has been built: 0 not yet, 1 being built, 2 built. (No TypeScript counterpart: a module
// is loaded once, before anything uses it.)
//
var defaultMimeState = std.atomic.Value(u8).init(0);

//
// Gets the default instance (TypeScript: the module's default export).
//
pub fn mime() !*const Mime {
    while (true) {
        switch (defaultMimeState.load(.acquire)) {
            2 => return &defaultMime,
            0 => {
                if (defaultMimeState.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
                    defaultMime = Mime.init(mime_allocator, &.{ &standardTypes, &otherTypes }) catch |err| {
                        defaultMimeState.store(0, .release);
                        return err;
                    };
                    defaultMimeState.store(2, .release);
                    return &defaultMime;
                }
            },
            else => std.atomic.spinLoopHint(),
        }
    }
}
