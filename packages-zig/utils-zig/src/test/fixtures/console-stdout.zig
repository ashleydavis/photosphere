const std = @import("std");
const utils = @import("utils-zig");

//
// Writes through console.log and console.debug with nothing captured, so the lines go to the real stdout, which the
// build checks. (The unit tests cannot do this themselves: under the build runner their stdout is the channel the
// test program reports its results on.)
//
pub fn main() void {
    utils.console.log("logged to stdout");
    utils.console.debug("debugged to stdout");
}
