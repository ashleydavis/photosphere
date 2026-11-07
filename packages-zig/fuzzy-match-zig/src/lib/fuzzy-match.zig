const std = @import("std");

//
// Converts UTF-8 text to UTF-16 code units, so that lengths and indexes count UTF-16 code units.
// Invalid UTF-8 falls back to one code unit per byte.
// (A byte sequence that is not UTF-8 is compared a byte at a time.)
//
fn toCodeUnits(allocator: std.mem.Allocator, text: []const u8) ![]const u16 {
    return std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        const code_units = try allocator.alloc(u16, text.len);
        for (text, 0..) |byte, index| {
            code_units[index] = byte;
        }
        return code_units;
    };
}

//
// Computes the Levenshtein edit distance between two strings using dynamic programming.
// Distances are counted in UTF-16 code units.
//
pub fn levenshteinDistance(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !usize {
    const first = try toCodeUnits(allocator, left);
    defer allocator.free(first);
    const second = try toCodeUnits(allocator, right);
    defer allocator.free(second);

    const columns = first.len + 1;
    const matrix = try allocator.alloc(usize, (second.len + 1) * columns);
    defer allocator.free(matrix);

    for (0..second.len + 1) |row| {
        matrix[row * columns] = row;
    }

    for (0..first.len + 1) |column| {
        matrix[column] = column;
    }

    for (1..second.len + 1) |row| {
        for (1..first.len + 1) |column| {
            if (second[row - 1] == first[column - 1]) {
                matrix[row * columns + column] = matrix[(row - 1) * columns + column - 1];
            }
            else {
                matrix[row * columns + column] = @min(
                    matrix[(row - 1) * columns + column - 1] + 1,
                    matrix[row * columns + column - 1] + 1,
                    matrix[(row - 1) * columns + column] + 1,
                );
            }
        }
    }

    return matrix[second.len * columns + first.len];
}

//
// Returns candidates whose Levenshtein edit distance from the query is within
// the threshold: distance > 0 && distance <= max(3, floor(query.length / 4)).
// Comparison is case-insensitive (ASCII letters only; non-ASCII letters are compared as they are).
// The returned slice refers to the candidate strings and is allocated with `allocator`.
//
pub fn fuzzyMatch(allocator: std.mem.Allocator, query: []const u8, candidates: []const []const u8) ![]const []const u8 {
    // TODO: lowercases ASCII letters only, where a full lowercase conversion lowercases every letter that has a
    // lowercase form, so a query and a candidate that differ only in the case of a non-ASCII letter should count as the
    // same string (and be skipped, because the distance has to be above zero) but differ here, which returns them.
    // Fixing it needs a Unicode case-folding table.
    const lowerQuery = try std.ascii.allocLowerString(allocator, query);
    defer allocator.free(lowerQuery);
    const queryCodeUnits = try toCodeUnits(allocator, lowerQuery);
    defer allocator.free(queryCodeUnits);
    const threshold = @max(3, queryCodeUnits.len / 4);

    var matches: std.ArrayList([]const u8) = .empty;
    errdefer matches.deinit(allocator);
    for (candidates) |candidate| {
        // TODO: lowercases ASCII letters only, as for the query above.
        const lowerCandidate = try std.ascii.allocLowerString(allocator, candidate);
        defer allocator.free(lowerCandidate);
        const distance = try levenshteinDistance(allocator, lowerQuery, lowerCandidate);
        if (distance > 0 and distance <= threshold) {
            try matches.append(allocator, candidate);
        }
    }
    return matches.toOwnedSlice(allocator);
}
