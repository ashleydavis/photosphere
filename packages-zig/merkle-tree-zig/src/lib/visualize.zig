const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const merkle_tree = @import("merkle-tree.zig");
const errors = utils.errors;
const bson = serialization_zig.bson;
const writeNumber = serialization_zig.js_number.writeNumber;
const IMerkleTree = merkle_tree.IMerkleTree;
const SortNode = merkle_tree.SortNode;
const MerkleNode = merkle_tree.MerkleNode;
const iterateLeaves = merkle_tree.iterateLeaves;

//
// Writes the short form of a hash: the first and last byte in hex
// (TypeScript: `hashHex.substring(0,2) + hashHex.substring(hashHex.length - 2)`).
//
fn writeShortHash(writer: *std.Io.Writer, hash: []const u8) !void {
    if (hash.len == 0) {
        return;
    }
    try writer.print("{x}{x}", .{ hash[0..1], hash[hash.len - 1 ..] });
}

//
// Visualize a sort tree in simple ASCII format showing item names
// (Zig: writes to `writer` instead of returning the string; `prefix` and `isLast` have no defaults; `allocator`
// allocates the prefixes of the children).
//
pub fn visualizeSortTree(allocator: std.mem.Allocator, writer: *std.Io.Writer, node: ?*const SortNode, prefix: []const u8, isLast: bool) !void {
    const current = node orelse {
        return;
    };

    const connector = if (isLast) "└── " else "├── ";

    try writer.writeAll(prefix);
    try writer.writeAll(connector);

    if (current.nodeCount == 1) {
        const name = current.name orelse {
            return errors.throwError("Leaf node has no name. This could be a bug.", .{});
        };

        const contentHash = current.contentHash orelse {
            return errors.throwError("Leaf node has no content hash. This could be a bug.", .{});
        };

        try writer.print("{s} (", .{name});
        try writeShortHash(writer, contentHash);
        try writer.writeAll(")");
    }
    else {
        try writer.print("{s} ({d})", .{ current.minName, current.nodeCount });
    }

    try writer.writeAll("\n");

    // Add children
    const newPrefix = try std.mem.concat(allocator, u8, &.{ prefix, if (isLast) "    " else "│   " });

    if (current.left) |left| {
        try visualizeSortTree(allocator, writer, left, newPrefix, current.right == null);
    }
    if (current.right) |right| {
        try visualizeSortTree(allocator, writer, right, newPrefix, true);
    }
}

//
// Visualize a Merkle tree in simple ASCII format showing hashes
// (Zig: writes to `writer` instead of returning the string; `prefix` and `isLast` have no defaults; `allocator`
// allocates the prefixes of the children).
//
pub fn visualizeMerkleTree(allocator: std.mem.Allocator, writer: *std.Io.Writer, node: ?*const MerkleNode, prefix: []const u8, isLast: bool) !void {
    const current = node orelse {
        return;
    };

    const connector = if (isLast) "└── " else "├── ";

    try writer.writeAll(prefix);
    try writer.writeAll(connector);

    if (current.left == null and current.right == null) {
        try writer.writeAll(" ");
        try writeShortHash(writer, current.hash);
        try writer.print(" {s}", .{current.name orelse "undefined"});
    }
    else {
        try writer.writeAll(" ");
        try writeShortHash(writer, current.hash);
    }

    try writer.writeAll("\n");

    // Add children
    const newPrefix = try std.mem.concat(allocator, u8, &.{ prefix, if (isLast) "    " else "│   " });

    if (current.left) |left| {
        try visualizeMerkleTree(allocator, writer, left, newPrefix, current.right == null);
    }
    if (current.right) |right| {
        try visualizeMerkleTree(allocator, writer, right, newPrefix, true);
    }
}

//
// Writes a database metadata value like the template string `${value}` (String(value)). Only the primitive values
// a tree's database metadata holds are ported; any other value throws.
//
fn writeMetadataValue(writer: *std.Io.Writer, value: bson.BsonValue) !void {
    switch (value) {
        .number => |number| {
            try writeNumber(writer, number);
        },
        .string => |text| {
            try writer.writeAll(text);
        },
        .boolean => |boolean| {
            try writer.writeAll(if (boolean) "true" else "false");
        },
        .null => {
            try writer.writeAll("null");
        },
        .undefined => {
            try writer.writeAll("undefined");
        },
        else => {
            return errors.throwError("String() of a {s} database metadata value is not ported", .{@tagName(value)});
        },
    }
}

//
// Writes a line of 50 equals signs and a newline (TypeScript: `"=".repeat(50) + "\n"`).
//
fn writeRule(writer: *std.Io.Writer) !void {
    try writer.splatByteAll('=', 50);
    try writer.writeAll("\n");
}

//
// Visualize both the sort tree and merkle tree for a complete view
//
// @param merkleTree The Merkle tree to visualize
// @returns A string representation of both trees
//
pub fn visualizeTree(allocator: std.mem.Allocator, merkleTree: ?*const IMerkleTree) ![]const u8 {
    const tree = merkleTree orelse {
        return "Empty tree";
    };
    if (tree.sort == null) {
        return "Empty tree";
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;

    // Add metadata
    try writer.writeAll("Tree Metadata:\n");
    try writer.print("  UUID: {s}\n", .{tree.id});
    try writer.print("  Total Nodes: {d}\n", .{tree.sort.?.nodeCount});
    try writer.print("  Total Items: {d}\n", .{tree.sort.?.leafCount});
    try writer.print("  Total Size: {d} bytes\n", .{tree.sort.?.size});

    // Add database metadata if available (version 3+)
    if (tree.databaseMetadata) |databaseMetadata| {
        try writer.writeAll("\nDatabase Metadata:\n");

        // Show all database metadata fields
        for (databaseMetadata.fields.items) |field| {
            try writer.print("  {s}: ", .{field.key});
            try writeMetadataValue(writer, field.value);
            try writer.writeAll("\n");
        }
    }

    try writer.print("\nVersion: {d}\n", .{tree.version});

    // Visualize the sort tree
    try writer.writeAll("\n");
    try writeRule(writer);
    try writer.writeAll("Sort Tree:\n");
    try writeRule(writer);
    try writer.writeAll("\n");
    try visualizeSortTree(allocator, writer, tree.sort, "", true);

    // Visualize the merkle tree
    if (tree.merkle) |merkle| {
        try writer.writeAll("\n");
        try writeRule(writer);
        try writer.writeAll("Merkle Tree:\n");
        try writeRule(writer);
        try writer.writeAll("\n");
        try visualizeMerkleTree(allocator, writer, merkle, "", true);

        try writer.writeAll("\n");
        try writeRule(writer);
        try writer.print("Root Hash: {x}\n", .{merkle.hash});
        try writeRule(writer);

        // List all leaf nodes
        try writer.writeAll("\n");
        try writeRule(writer);
        try writer.writeAll("Leaf Nodes:\n");
        try writeRule(writer);
        var leaves = iterateLeaves(MerkleNode, allocator, merkle);
        while (try leaves.next()) |leaf| {
            if (leaf.name != null and leaf.name.?.len > 0) {
                try writer.print("{s} ({x})\n", .{ leaf.name.?, leaf.hash });
            }
        }
        try writeRule(writer);
    }

    return output.written();
}
