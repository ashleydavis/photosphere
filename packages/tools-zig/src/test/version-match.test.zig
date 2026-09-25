const std = @import("std");
const tools = @import("tools-zig");
const version_match = tools.version_match;

test "matchAfter finds the characters after the prefix" {
    try std.testing.expectEqualStrings("7.1.1-29", version_match.matchAfter("Version: ImageMagick 7.1.1-29 Q16", "Version: ImageMagick ", version_match.isVersionNumberCharacter).?);
    try std.testing.expectEqualStrings("n7.0", version_match.matchAfter("ffmpeg version n7.0 Copyright", "ffmpeg version ", version_match.isNonWhitespaceCharacter).?);
}

test "matchAfter needs at least one matching character" {
    try std.testing.expect(version_match.matchAfter("Version: ImageMagick abc", "Version: ImageMagick ", version_match.isVersionNumberCharacter) == null);
    try std.testing.expect(version_match.matchAfter("nothing here", "ffmpeg version ", version_match.isNonWhitespaceCharacter) == null);
}

test "matchAfter keeps searching after a failed match" {
    try std.testing.expectEqualStrings("1.2", version_match.matchAfter("v: x v: 1.2", "v: ", version_match.isVersionNumberCharacter).?);
}
