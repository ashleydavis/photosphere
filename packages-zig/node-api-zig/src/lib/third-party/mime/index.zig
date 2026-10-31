//
// Port of mime 4.1.0 src/index.ts: the default Mime instance, knowing the standard and the other types.
//
// mime (c) 2023 Robert Kieffer, MIT license.
//

const std = @import("std");
const ziggy = @import("ziggy");
const Mime = @import("Mime.zig").Mime;
const standardTypes = @import("types/standard.zig").types;
const otherTypes = @import("types/other.zig").types;

//
// The allocator of the calling thread's default instance, which lives as long as the thread. Each thread has its own, so no allocator
// is used by two threads. It is a thread-local rather than an argument because mime() is called as the TypeScript module's default
// export is, without one.
//
threadlocal var mime_allocator: ziggy.utils.thread_allocator.ThreadAllocator = .init;

//
// The default instance of the calling thread (TypeScript: `new Mime(standardTypes, otherTypes)._freeze()`, built when the module loads;
// here it is built on first use by each thread, so the threads share nothing).
//
threadlocal var defaultMime: ?Mime = null;

//
// Gets the default instance (TypeScript: the module's default export).
//
pub fn mime() !*const Mime {
    if (defaultMime == null) {
        defaultMime = try Mime.init(mime_allocator.allocator(), &.{ &standardTypes, &otherTypes });
    }
    return &defaultMime.?;
}
