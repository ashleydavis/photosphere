const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const storage_zig = @import("storage-zig");
const traverse = @import("traverse.zig");
const buffer_set = @import("buffer-set.zig");
const buffer_map = @import("buffer-map.zig");
const errors = utils.errors;
const serialization = serialization_zig.serialization;
const bson = serialization_zig.bson;
const IStorage = storage_zig.storage.IStorage;
const ISerializer = serialization.ISerializer;
const IDeserializer = serialization.IDeserializer;
const CompressedBinarySerializer = serialization.CompressedBinarySerializer;
const CompressedBinaryDeserializer = serialization.CompressedBinaryDeserializer;
const BufferSet = buffer_set.BufferSet;
const BufferMap = buffer_map.BufferMap;
const Sha256 = std.crypto.hash.sha2.Sha256;

// Not ported: traverseTreeSync import (only used by binaryTreeToArray and rebuildTree, which are not ported).

//
// Current database version
//
pub const CURRENT_DATABASE_VERSION: u32 = 6;

//
// Generic node interface for traversal.
// (Zig: INode<NodeT> is not a type; the generic functions take `comptime NodeT: type`, which must be a struct with
// `left: ?*NodeT` and `right: ?*NodeT` fields, such as SortNode and MerkleNode.)
//

//
// Represents a node in the Merkle tree.
//
pub const SortNode = struct { //todo: Would be nice to have SortLeaf and SortParent. They have different properties!
    // The hash of the content, for leaf nodes only.
    contentHash: ?[]const u8 = null,

    // The name/identifier this hash represents, for leaf nodes only.
    name: ?[]const u8 = null,

    // Number of nodes in the subtree rooted at this node (including this node). Set to 1 for leaf nodes.
    nodeCount: u32,

    // Number of leaf nodes in the subtree rooted at this node. Computed during deserialization, not serialized.
    leafCount: u32,

    // The size of the node and children in bytes.
    size: u64,

    // The last modified date (for leaf nodes only, version 3+), in milliseconds since the Unix epoch.
    lastModified: ?i64 = null,

    // The minimum name in this subtree (for efficient sorted insertion).
    minName: []const u8,

    // Left child node
    left: ?*SortNode = null,

    // Right child node
    right: ?*SortNode = null,
};

//
// Represents a merkle tree node.
//
pub const MerkleNode = struct {
    // The hash of this node.
    hash: []const u8,

    // Number of nodes in the subtree rooted at this node (including this node). Set to 1 for leaf nodes.
    nodeCount: u32,

    // The name/identifier of the item (only set for leaf nodes).
    name: ?[]const u8 = null,

    // Left child node
    left: ?*MerkleNode = null,

    // Right child node
    right: ?*MerkleNode = null,
};

//
// The hash and other information about an item.
//
pub const IHashedData = struct {
    //
    // The sha256 hash of the item.
    //
    hash: []const u8,

    //
    // The length/size of the item in bytes.
    //
    length: u64,

    //
    // The last modified date of the item (milliseconds since the Unix epoch).
    //
    lastModified: i64,
};

//
// Represents a hashed item to add to the Merkle tree.
// (Zig: `extends IHashedData` is written out as the same fields plus name.)
//
pub const HashedItem = struct {
    // The name/identifier of the item.
    name: []const u8,

    // The sha256 hash of the item.
    hash: []const u8,

    // The length/size of the item in bytes.
    length: u64,

    // The last modified date of the item (milliseconds since the Unix epoch).
    lastModified: i64,
};

//
// Represents the merkle tree itself.
// (Zig: the TypeScript `DatabaseMetadata` type parameter is represented by a BSON document, because the metadata is
// stored as BSON in the tree file. Callers that need typed metadata (node-api's IDatabaseMetadata) read the fields
// from the document. A loaded tree always has a document (TypeScript loads `{}` for trees saved without metadata).)
//
pub const IMerkleTree = struct {
    //
    // A UUID that uniquely identifies the tree
    //
    id: []const u8,

    //
    // The root of the binary sort tree.
    //
    sort: ?*SortNode = null,

    //
    // Set to true if the tree is dirty and needs to be rebuilt.
    //
    dirty: bool,

    //
    // The root of the Merkle tree.
    //
    merkle: ?*MerkleNode = null,

    //
    // Database metadata (only in version 3+)
    // This replaces the separate metadata.json file
    //
    databaseMetadata: ?bson.BsonDocument = null,

    //
    // Version of the merkle tree file format
    //
    version: u32,
};

//
// Find an item node in the binary tree by name.
// This is the core tree traversal function that should be reused everywhere.
//
pub fn findItemInTree(node: ?*SortNode, targetName: []const u8) ?*SortNode {
    const currentNode = node orelse {
        return null;
    };

    if (currentNode.nodeCount == 1) {
        if (currentNode.name != null and std.mem.eql(u8, currentNode.name.?, targetName)) {
            return currentNode;
        }
        return null;
    }

    if (findItemInTree(currentNode.left, targetName)) |leftResult| {
        return leftResult;
    }

    return findItemInTree(currentNode.right, targetName);
}

//
// Generic function to find and update a node in the binary tree.
// The updater function should return true if the node was updated, false otherwise.
// If a node is updated, parent nodes will have their properties recalculated.
// (Zig: the updater receives a caller supplied `context` in place of the variables a TypeScript closure captures.)
//
pub fn updateNodeInTree(
    comptime T: type,
    node: *SortNode,
    targetName: []const u8,
    context: anytype,
    updater: *const fn (@TypeOf(context), *SortNode, []const u8) T,
) ?T {
    // If this is a leaf node, check if it's the target
    if (node.nodeCount == 1) {
        if (node.name != null and std.mem.eql(u8, node.name.?, targetName)) {
            return updater(context, node, targetName);
        }
        return null; // Not the target
    }

    // Internal node - recursively check children
    var result: ?T = null;

    // Check left subtree
    if (node.left) |left| {
        result = updateNodeInTree(T, left, targetName, context, updater);
    }

    // Check right subtree (only if not found in left)
    // (Zig: TypeScript's `!result` also skips a falsy result; the only updater, in updateItem, always returns true.)
    if (result == null) {
        if (node.right) |right| {
            result = updateNodeInTree(T, right, targetName, context, updater);
        }
    }

    // If a child was updated, recalculate this node's properties
    if (result != null) {
        const leftSize = if (node.left) |left| left.size else 0;
        const rightSize = if (node.right) |right| right.size else 0;
        node.size = leftSize + rightSize;
    }

    return result;
}

//
// Combine two hashes to create a parent hash.
//
pub fn combineHashes(leftHash: []const u8, rightHash: []const u8) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(leftHash);
    hasher.update(rightHash);
    return hasher.finalResult();
}

//
// Compare two names for sorting in the merkle tree.
// Returns negative if a < b, zero if equal, positive if a > b.
// Uses natural/numeric-aware sorting for intuitive ordering.
// (Zig: TypeScript calls `a.localeCompare(b, undefined, { numeric: true })`, which is ICU root collation with numeric
// ordering. Zig has no ICU, so this emulates it for the names the trees hold: every ASCII character has its ICU
// primary weight (control characters are ignorable, punctuation sorts before digits, letters compare case-insensitively
// first and then lowercase before uppercase), and each run of digits compares by numeric value. Non-ASCII characters
// sort after all ASCII characters by code point, which differs from ICU (for example ICU sorts "é" next to "e").
// Golden tests compare this with localeCompare on generated names.)
//
pub fn compareNames(a: []const u8, b: []const u8) i32 {
    // Primary level: compare the weights of the characters, numbers by value.
    var leftElements: CollationIterator = .{ .text = a, .index = 0 };
    var rightElements: CollationIterator = .{ .text = b, .index = 0 };
    while (true) {
        const leftElement = leftElements.next();
        const rightElement = rightElements.next();
        if (leftElement == null and rightElement == null) {
            break;
        }
        if (leftElement == null) {
            return -1;
        }
        if (rightElement == null) {
            return 1;
        }
        const order = comparePrimaryWeights(leftElement.?, rightElement.?);
        if (order != 0) {
            return order;
        }
    }

    // Tertiary level: the first difference in case decides (lowercase first).
    leftElements = .{ .text = a, .index = 0 };
    rightElements = .{ .text = b, .index = 0 };
    while (true) {
        const leftElement = leftElements.next() orelse {
            break;
        };
        const rightElement = rightElements.next() orelse {
            break;
        };
        if (leftElement.tertiary < rightElement.tertiary) {
            return -1;
        }
        if (leftElement.tertiary > rightElement.tertiary) {
            return 1;
        }
    }
    return 0;
}

//
// ICU root collation order of the ASCII characters that are not ignorable (the order `localeCompare` sorts them in).
// A lowercase letter and its uppercase letter have the same primary weight. (No TypeScript counterpart.)
//
const ascii_collation_order = "\t\n\x0b\x0c\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ";

//
// The primary weight of an ignorable character (control characters). (No TypeScript counterpart.)
//
const IGNORABLE_WEIGHT: u32 = 0;

//
// The primary weight of every non-ignorable ASCII character, indexed by the character. (No TypeScript counterpart.)
//
const ascii_primary_weights: [128]u32 = weights: {
    var weights = [_]u32{IGNORABLE_WEIGHT} ** 128;
    var weight: u32 = 0;
    for (ascii_collation_order) |character| {
        if (character >= 'A' and character <= 'Z') {
            weights[character] = weights[character + ('a' - 'A')];
        }
        else {
            weight += 1;
            weights[character] = weight;
        }
    }
    break :weights weights;
};

//
// The primary weight of a run of digits (compared by numeric value among themselves). (No TypeScript counterpart.)
//
const NUMBER_WEIGHT: u32 = ascii_primary_weights['0'];

//
// The primary weight added to the code point of a non-ASCII character. (No TypeScript counterpart.)
//
const NON_ASCII_WEIGHT_BASE: u32 = 0x10000;

//
// One collation element of a name: a character, or a whole run of digits. (No TypeScript counterpart.)
//
const CollationElement = struct {
    // The primary weight.
    primary: u32,

    // For a run of digits, the digits without leading zeros (empty otherwise).
    digits: []const u8,

    // The tertiary (case) weight: 1 for uppercase letters, 0 otherwise.
    tertiary: u8,
};

//
// Yields the collation elements of a name, skipping ignorable characters. (No TypeScript counterpart.)
//
const CollationIterator = struct {
    // The UTF-8 name.
    text: []const u8,

    // The index of the next byte to read.
    index: usize,

    //
    // Returns the next collation element or null at the end of the name.
    //
    fn next(self: *CollationIterator) ?CollationElement {
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (std.ascii.isDigit(byte)) {
                const start = self.index;
                while (self.index < self.text.len and std.ascii.isDigit(self.text[self.index])) {
                    self.index += 1;
                }
                var digits = self.text[start..self.index];
                while (digits.len > 0 and digits[0] == '0') {
                    digits = digits[1..];
                }
                return .{ .primary = NUMBER_WEIGHT, .digits = digits, .tertiary = 0 };
            }
            if (byte < 0x80) {
                self.index += 1;
                const weight = ascii_primary_weights[byte];
                if (weight == IGNORABLE_WEIGHT) {
                    continue;
                }
                const tertiary: u8 = if (std.ascii.isUpper(byte)) 1 else 0;
                return .{ .primary = weight, .digits = "", .tertiary = tertiary };
            }
            const codePoint = decodeCodePoint(self.text, &self.index);
            return .{ .primary = NON_ASCII_WEIGHT_BASE + codePoint, .digits = "", .tertiary = 0 };
        }
        return null;
    }
};

//
// Decodes the UTF-8 code point at index (advancing it); invalid bytes decode as U+FFFD one byte at a time.
// (No TypeScript counterpart.)
//
fn decodeCodePoint(text: []const u8, index: *usize) u21 {
    const sequenceLength = std.unicode.utf8ByteSequenceLength(text[index.*]) catch {
        index.* += 1;
        return 0xFFFD;
    };
    if (index.* + sequenceLength > text.len) {
        index.* += 1;
        return 0xFFFD;
    }
    const codePoint = std.unicode.utf8Decode(text[index.* .. index.* + sequenceLength]) catch {
        index.* += 1;
        return 0xFFFD;
    };
    index.* += sequenceLength;
    return codePoint;
}

//
// Compares the primary weights of two collation elements (numbers by value). (No TypeScript counterpart.)
//
fn comparePrimaryWeights(left: CollationElement, right: CollationElement) i32 {
    if (left.primary != right.primary) {
        if (left.primary < right.primary) {
            return -1;
        }
        return 1;
    }
    if (left.primary == NUMBER_WEIGHT) {
        if (left.digits.len != right.digits.len) {
            if (left.digits.len < right.digits.len) {
                return -1;
            }
            return 1;
        }
        return switch (std.mem.order(u8, left.digits, right.digits)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }
    return 0;
}

//
// Yields the UTF-16 code units of a UTF-8 string. (No TypeScript counterpart: JavaScript strings are UTF-16.)
//
const Utf16Iterator = struct {
    // The UTF-8 string.
    text: []const u8,

    // The index of the next byte to read.
    index: usize,

    // The low surrogate still to be returned for a code point above U+FFFF.
    pendingLowSurrogate: ?u16,

    //
    // Returns the next UTF-16 code unit or null at the end of the string.
    //
    fn next(self: *Utf16Iterator) ?u16 {
        if (self.pendingLowSurrogate) |lowSurrogate| {
            self.pendingLowSurrogate = null;
            return lowSurrogate;
        }
        if (self.index >= self.text.len) {
            return null;
        }
        const codePoint = decodeCodePoint(self.text, &self.index);
        if (codePoint >= 0x10000) {
            const offset: u32 = codePoint - 0x10000;
            self.pendingLowSurrogate = @intCast(0xDC00 + (offset & 0x3FF));
            return @intCast(0xD800 + (offset >> 10));
        }
        return @intCast(codePoint);
    }
};

//
// The ordering of JavaScript's default `Array.prototype.sort()` for strings (UTF-16 code unit order).
// (No TypeScript counterpart.)
//
fn lessThanUtf16(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    var leftUnits: Utf16Iterator = .{ .text = left, .index = 0, .pendingLowSurrogate = null };
    var rightUnits: Utf16Iterator = .{ .text = right, .index = 0, .pendingLowSurrogate = null };
    while (true) {
        const leftUnit = leftUnits.next();
        const rightUnit = rightUnits.next();
        if (rightUnit == null) {
            return false;
        }
        if (leftUnit == null) {
            return true;
        }
        if (leftUnit.? != rightUnit.?) {
            return leftUnit.? < rightUnit.?;
        }
    }
}

//
// Create a new leaf node for an item
//
pub fn createLeafNode(allocator: std.mem.Allocator, item: HashedItem) !*SortNode {
    const node = try allocator.create(SortNode);
    node.* = .{
        .contentHash = item.hash,
        .name = item.name,
        .nodeCount = 1, // Leaf nodes have a node count of 1.
        .leafCount = 1, // Leaf nodes have a leaf count of 1.
        .size = item.length, // Size is the length of the item.
        .lastModified = item.lastModified, // Include last modified date if provided.
        .minName = item.name, // For leaf nodes, minName is the name itself.
    };
    return node;
}

//
// Create a parent node from two child nodes
//
pub fn createParentNode(allocator: std.mem.Allocator, left: *SortNode, right: *SortNode) !*SortNode {
    const node = try allocator.create(SortNode);
    node.* = .{
        .name = null, // Internal nodes don't represent an item
        .nodeCount = 1 + left.nodeCount + right.nodeCount, // Total node count is 1 (this node) + left + right
        .leafCount = left.leafCount + right.leafCount, // Total leaf count is sum of children
        .size = left.size + right.size, // Total size is the sum of both subtrees.
        .minName = left.minName, // Since we maintain sorted order, the min name is always the min of the left subtree
        .left = left,
        .right = right,
    };
    return node;
}

// Not ported: binaryTreeToArray (only used by tests and tools, not by psi replicate or psi verify).

//
// A sort node as stored in the flat node arrays of version 2 and 3 files (TypeScript: `Omit<SortNode, 'minName'>`).
//
pub const FlatSortNode = struct {
    // The hash of the content, for leaf nodes only.
    contentHash: ?[]const u8 = null,

    // The name/identifier this hash represents.
    name: ?[]const u8 = null,

    // Number of nodes in the subtree rooted at this node (including this node).
    nodeCount: u32,

    // Number of leaf nodes in the subtree rooted at this node.
    leafCount: u32,

    // The size of the node and children in bytes.
    size: u64,

    // The last modified date (milliseconds since the Unix epoch).
    lastModified: ?i64 = null,
};

//
// Convert flat array to binary tree (for loading)
//
pub fn arrayToBinaryTree(allocator: std.mem.Allocator, nodes: []const FlatSortNode) !?*SortNode {
    if (nodes.len == 0) {
        return null;
    }

    // For now, use a simple approach - rebuild tree structure based on the array
    // This assumes the array was created by depth-first traversal
    var index: usize = 0;

    const Builder = struct {
        // Builds the node at nextIndex and its children (TypeScript: the nested buildNode function).
        fn buildNode(builderAllocator: std.mem.Allocator, flatNodes: []const FlatSortNode, nextIndex: *usize) !?*SortNode {
            if (nextIndex.* >= flatNodes.len) {
                return null;
            }

            const flatNode = flatNodes[nextIndex.*];
            nextIndex.* += 1;

            const node = try builderAllocator.create(SortNode);
            if (flatNode.nodeCount == 1) {
                // Leaf node - no children
                node.* = .{
                    .contentHash = flatNode.contentHash,
                    .name = flatNode.name,
                    .nodeCount = flatNode.nodeCount,
                    .leafCount = 1,
                    .size = flatNode.size,
                    .lastModified = flatNode.lastModified,
                    .minName = flatNode.name orelse "",
                };
                return node;
            }

            // Internal node - recursively build left and right
            const left = try buildNode(builderAllocator, flatNodes, nextIndex);
            const right = try buildNode(builderAllocator, flatNodes, nextIndex);

            node.* = .{
                .contentHash = flatNode.contentHash,
                .name = flatNode.name,
                .nodeCount = flatNode.nodeCount,
                .leafCount = left.?.leafCount + right.?.leafCount,
                .size = flatNode.size,
                .lastModified = flatNode.lastModified,
                .minName = left.?.minName,
                .left = left,
                .right = right,
            };
            return node;
        }
    };

    return Builder.buildNode(allocator, nodes, &index);
}

//
// Rebalance a tree using AVL-like rotations to maintain both sorting and balance
//
// This function checks if a tree is balanced and performs rotations if needed.
// A tree is considered balanced if the difference between left and right subtree
// node counts is 2 or less.
//
// @param node - The node to potentially rebalance
// @returns The rebalanced node
//
pub fn rebalanceTree(allocator: std.mem.Allocator, node: *SortNode) !*SortNode {
    const left = node.left orelse {
        return errors.throwError("Invalid tree structure", .{});
    };
    const right = node.right orelse {
        return errors.throwError("Invalid tree structure", .{});
    };

    const leftCount: i64 = left.nodeCount;
    const rightCount: i64 = right.nodeCount;
    const balance = leftCount - rightCount;

    if (balance > 2) {
        // Left-heavy tree (leftCount > rightCount + 1)
        // Allows the tree to be slightly left-heavy.

        const leftLeftCount: u32 = if (left.left) |leftLeft| leftLeft.nodeCount else 0;
        const leftRightCount: u32 = if (left.right) |leftRight| leftRight.nodeCount else 0;

        // Left-Left case: rotate right
        if (leftLeftCount >= leftRightCount) {
            return rotateRight(allocator, node);
        }
        // Left-Right case: rotate left then right
        else {
            const newLeft = try rotateLeft(allocator, node.left.?);
            const newNode = try allocator.create(SortNode);
            newNode.* = node.*;
            newNode.left = newLeft;
            return rotateRight(allocator, newNode);
        }
    }
    else if (balance < 0) {
        // Right-heavy tree (rightCount > leftCount + 1)
        // We don't tollerate right heavy trees in the interest of producing
        // equivalent trees regardless of the order of insertion.
        const rightLeftCount: u32 = if (right.left) |rightLeft| rightLeft.nodeCount else 0;
        const rightRightCount: u32 = if (right.right) |rightRight| rightRight.nodeCount else 0;

        // Right-Right case: rotate left
        if (rightRightCount >= rightLeftCount) {
            return rotateLeft(allocator, node);
        }
        // Right-Left case: rotate right then left
        else {
            const newRight = try rotateRight(allocator, right);
            const newNode = try allocator.create(SortNode);
            newNode.* = node.*;
            newNode.right = newRight;
            return rotateLeft(allocator, newNode);
        }
    }
    else {
        // If tree is reasonably balanced (difference <= 2), no rotation needed.
        return node;
    }
}

//
// Rotate right to balance the tree
//
// This function performs a right rotation to rebalance the tree structure.
// The left child of the input node becomes the new root, and the original
// node becomes the right child of the new root.
//
// @param node - The node to rotate
// @returns The rotated node
//
pub fn rotateRight(allocator: std.mem.Allocator, node: *SortNode) !*SortNode {
    const left = node.left orelse {
        return errors.throwError("Invalid tree structure", .{});
    };
    const right = node.right orelse {
        return errors.throwError("Invalid tree structure", .{});
    };

    const newLeft = left.left orelse {
        return errors.throwError("Invalid tree structure", .{});
    };
    const newCenter = left.right orelse {
        return errors.throwError("Invalid tree structure", .{});
    };

    const newRight = try allocator.create(SortNode);
    newRight.* = .{
        .left = newCenter,
        .right = right,
        .nodeCount = 1 + newCenter.nodeCount + right.nodeCount,
        .leafCount = newCenter.leafCount + right.leafCount,
        .size = newCenter.size + right.size,
        .minName = newCenter.minName,
    };
    const newNode = try allocator.create(SortNode);
    newNode.* = .{
        .nodeCount = 1 + newLeft.nodeCount + 1 + newCenter.nodeCount + right.nodeCount,
        .leafCount = newLeft.leafCount + newCenter.leafCount + right.leafCount,
        .size = newLeft.size + newCenter.size + right.size,
        .minName = newLeft.minName,
        .left = newLeft,
        .right = newRight,
    };
    return newNode;
}

//
// Rotate left to balance the tree
//
// This function performs a left rotation to rebalance the tree structure.
// The right child of the input node becomes the new root, and the original
// node becomes the left child of the new root.
//
// @param node - The node to rotate
// @returns The rotated node
//
pub fn rotateLeft(allocator: std.mem.Allocator, node: *SortNode) !*SortNode {
    const left = node.left orelse {
        return errors.throwError("Invalid tree structure", .{});
    };
    const right = node.right orelse {
        return errors.throwError("Invalid tree structure", .{});
    };

    const newRight = right.right orelse {
        return errors.throwError("Invalid tree structure", .{});
    };
    const newCenter = right.left orelse {
        return errors.throwError("Invalid tree structure", .{});
    };

    const newLeft = try allocator.create(SortNode);
    newLeft.* = .{
        .left = left,
        .right = newCenter,
        .nodeCount = 1 + left.nodeCount + newCenter.nodeCount,
        .leafCount = left.leafCount + newCenter.leafCount,
        .size = left.size + newCenter.size,
        .minName = left.minName,
    };
    const newNode = try allocator.create(SortNode);
    newNode.* = .{
        .nodeCount = 1 + 1 + left.nodeCount + newCenter.nodeCount + newRight.nodeCount,
        .leafCount = left.leafCount + newCenter.leafCount + newRight.leafCount,
        .size = left.size + newCenter.size + newRight.size,
        .minName = left.minName,
        .left = newLeft,
        .right = newRight,
    };
    return newNode;
}

//
// Add an item to the Merkle tree using binary tree structure (avoids recursion)
//
fn _addItem(allocator: std.mem.Allocator, node: ?*SortNode, item: HashedItem) !*SortNode {
    const newLeaf = try createLeafNode(allocator, item);

    const currentNode = node orelse {
        // If the tree is empty, return the new leaf as the root
        return newLeaf;
    };

    // If current node is a leaf, determine correct order and create parent
    if (currentNode.nodeCount == 1) {
        if (compareNames(item.name, currentNode.name.?) < 0) {
            return createParentNode(allocator, newLeaf, currentNode); // new item goes left
        }
        else {
            return createParentNode(allocator, currentNode, newLeaf); // new item goes right
        }
    }

    const left = currentNode.left orelse {
        return errors.throwError("Invalid tree structure", .{});
    };
    const right = currentNode.right orelse {
        return errors.throwError("Invalid tree structure", .{});
    };

    const rightMin = right.minName; // If not a leaf node, there must always be a right child with a minName.
    var newLeft = left;
    var newRight = right;

    if (compareNames(item.name, rightMin) < 0) {
        // Item should go in left subtree based on sorting
        newLeft = try _addItem(allocator, left, item);
    }
    else {
        // Item should go in right subtree based on sorting
        newRight = try _addItem(allocator, right, item);
    }

    // Create new node with updated children and recalculated properties
    const newLeftCount = newLeft.nodeCount;
    const newRightCount = newRight.nodeCount;
    const newLeftSize = newLeft.size;
    const newRightSize = newRight.size;

    const newNode = try allocator.create(SortNode);
    newNode.* = .{
        .left = newLeft,
        .right = newRight,
        .nodeCount = 1 + newLeftCount + newRightCount,
        .leafCount = newLeft.leafCount + newRight.leafCount,
        .size = newLeftSize + newRightSize,
        .minName = newLeft.minName,
    };

    return rebalanceTree(allocator, newNode);
}

//
// Create a new empty Merkle tree.
//
pub fn createTree(uuid: []const u8) IMerkleTree {
    return .{
        .id = uuid,
        .sort = null,
        .dirty = false,
        .merkle = null,
        .version = CURRENT_DATABASE_VERSION,
    };
}

//
// Add an item to the Merkle tree, efficiently creating a balanced structure
// without rebuilding the entire tree
//
pub fn addItem(
    allocator: std.mem.Allocator,
    merkleTree: *const IMerkleTree,
    item: HashedItem,
) !IMerkleTree {

    //
    // Adds the new leaf node to the merkle tree.
    //
    const sort = try _addItem(allocator, merkleTree.sort, item);

    return .{
        .id = merkleTree.id,
        .sort = sort,
        .dirty = true, // Mark the tree as dirty so it will be rebuilt later.
        .merkle = merkleTree.merkle,
        .version = if (merkleTree.version != 0) merkleTree.version else CURRENT_DATABASE_VERSION,
        .databaseMetadata = merkleTree.databaseMetadata,
    };
}

//
// Iterator returned by iterateLeaves (the Zig form of the TypeScript generator).
// Visits leaves in pre-order (node, left subtree, right subtree) and is lazy like a generator.
//
pub fn NodeIterator(comptime NodeT: type) type {
    return struct {
        const Self = @This();

        // Allocates the stack of nodes still to visit.
        allocator: std.mem.Allocator,

        // The nodes still to visit (the next node is at the end).
        stack: std.ArrayList(*NodeT),

        // The root node, until the first call to next.
        root: ?*NodeT,

        //
        // Returns the next node, or null when the iteration is finished.
        //
        pub fn next(self: *Self) !?*NodeT {
            if (self.root) |root| {
                self.root = null;
                try self.stack.append(self.allocator, root);
            }
            while (self.stack.pop()) |node| {
                if (node.right) |right| {
                    try self.stack.append(self.allocator, right);
                }
                if (node.left) |left| {
                    try self.stack.append(self.allocator, left);
                }
                if (node.left == null and node.right == null) {
                    return node;
                }
            }
            return null;
        }
    };
}

// Not ported: iterateNodes (not reached by psi replicate or psi verify)

//
// Iterates all leaves in the tree.
//
pub fn iterateLeaves(comptime NodeT: type, allocator: std.mem.Allocator, node: ?*NodeT) NodeIterator(NodeT) {
    return .{ .allocator = allocator, .stack = .empty, .root = node };
}

//
// Builds a merkle tree from a sort tree.
//
pub fn buildMerkleTree(allocator: std.mem.Allocator, sort: ?*SortNode) !?*MerkleNode {
    if (sort == null) {
        return null;
    }

    // Stack to hold nodes at each level during construction
    // Similar to binary addition with carries
    var stack: std.ArrayList(?*MerkleNode) = .empty;

    // Process each leaf node from the sort tree
    var leaves = iterateLeaves(SortNode, allocator, sort);
    while (try leaves.next()) |leaf| {
        const contentHash = leaf.contentHash orelse {
            return errors.throwError("Leaf node has no content hash", .{});
        };

        if (leaf.name == null or leaf.name.?.len == 0) {
            return errors.throwError("Leaf node has no name", .{});
        }

        var node = try allocator.create(MerkleNode);
        node.* = .{
            .hash = contentHash,
            .nodeCount = 1,
            .name = leaf.name,
        };

        // Try to combine this node with nodes at each level going up
        var level: usize = 0;
        while (level < stack.items.len and stack.items[level] != null) {
            // Combine with the node at this level
            const left = stack.items[level].?;
            const right = node;

            const hash = try allocator.create([Sha256.digest_length]u8);
            hash.* = combineHashes(left.hash, right.hash);
            node = try allocator.create(MerkleNode);
            node.* = .{
                .hash = hash,
                .nodeCount = left.nodeCount + right.nodeCount + 1,
                .left = left,
                .right = right,
            };

            // Clear this level and move up
            stack.items[level] = null;
            level += 1;
        }

        // Place the node at the current level
        if (level >= stack.items.len) {
            try stack.append(allocator, node);
        }
        else {
            stack.items[level] = node;
        }
    }

    // Combine any remaining nodes in the stack to preserve order
    // The stack is organized by tree level: lower indices are deeper (processed later, rightmost),
    // higher indices are higher (processed earlier, leftmost)
    // To preserve leaf order, we need to combine from high index to low index
    // (earlier/leftmost on left, later/rightmost on right)
    var stackNodes: std.ArrayList(*MerkleNode) = .empty;
    for (stack.items) |stackNode| {
        if (stackNode) |node| {
            try stackNodes.append(allocator, node);
        }
    }

    if (stackNodes.items.len == 0) {
        return null;
    }

    // Combine from last to first (high index to low): earlier nodes (high index) on left, later nodes (low index) on right
    var result = stackNodes.items[stackNodes.items.len - 1];
    var stackIndex = stackNodes.items.len - 1;
    while (stackIndex > 0) {
        stackIndex -= 1;
        // stackNodes[i] is later (lower index = deeper in tree), result is earlier (higher index = higher in tree)
        // To preserve order: earlier (result) on left, later (stackNodes[i]) on right
        const hash = try allocator.create([Sha256.digest_length]u8);
        hash.* = combineHashes(result.hash, stackNodes.items[stackIndex].hash);
        const combined = try allocator.create(MerkleNode);
        combined.* = .{
            .hash = hash,
            .nodeCount = result.nodeCount + stackNodes.items[stackIndex].nodeCount + 1,
            .left = result,
            .right = stackNodes.items[stackIndex],
        };
        result = combined;
    }

    return result;
}

//
// Upsert an item in the Merkle tree, either adding it or updating it if it already exists.
// Updates the tree in place.
//
pub fn upsertItem(
    allocator: std.mem.Allocator,
    merkleTree: *IMerkleTree,
    item: HashedItem,
) !IMerkleTree {
    if (merkleTree.sort != null) {
        if (try updateItem(merkleTree, item)) {
            // Item updated successfully in place.
            return merkleTree.*;
        }
    }

    return addItem(allocator, merkleTree, item);
}

//
// Update an item in the Merkle tree with new content, maintaining the same tree structure.
//
pub fn updateItem(
    merkleTree: ?*IMerkleTree,
    item: HashedItem,
) !bool {
    if (merkleTree == null or merkleTree.?.sort == null) {
        return errors.throwError("Tree is empty, cannot update item '{s}'", .{item.name});
    }
    const tree = merkleTree.?;

    const Updater = struct {
        // Updates the leaf node in place (TypeScript: the updater arrow function).
        fn update(updatedItem: *const HashedItem, node: *SortNode, targetName: []const u8) bool {
            _ = targetName;
            // Update the leaf node in place
            node.contentHash = updatedItem.hash;
            node.lastModified = updatedItem.lastModified;
            node.size = updatedItem.length; // Update the size with the new item length
            return true; // Found and updated
        }
    };

    // Use the centralized updateNodeInTree function to find and update the item
    const wasUpdated = updateNodeInTree(bool, tree.sort.?, item.name, &item, Updater.update) orelse false;

    if (wasUpdated) {
        tree.dirty = true; // Mark the tree as dirty so it will be rebuilt later.
    }

    return wasUpdated;
}

//
// Get item information from merkle tree (hash, size, lastModified)
// This replaces the need for database hash cache lookups
//
pub fn getItemInfo(merkleTree: *const IMerkleTree, name: []const u8) !?IHashedData {
    // Use the centralized findItemInTree function
    const leafNode = findItemInTree(merkleTree.sort, name) orelse {
        return null;
    };

    const lastModified = leafNode.lastModified orelse {
        return errors.throwError("Item {s} is missing lastModified date. This could be a bug.", .{name});
    };

    const contentHash = leafNode.contentHash orelse {
        return errors.throwError("Item {s} is missing content hash. This could be a bug.", .{name});
    };

    return .{
        .hash = contentHash,
        .length = leafNode.size,
        .lastModified = lastModified,
    };
}

// Not ported: findItemNode (not reached by psi replicate or psi verify)

//
// A 64-bit number split into 32-bit parts (TypeScript: `{ high: number, low: number }`).
//
const SplitNumber = struct {
    // The high 32 bits.
    high: u32,

    // The low 32 bits.
    low: u32,
};

//
// Splits a large number into high and low 32-bit parts.
//
fn splitBigNum(input: u64) SplitNumber {
    // Get low 32 bits using bitwise AND
    const low: u32 = @truncate(input & 0xFFFFFFFF);

    // Get high bits by right shifting 32 positions
    const high: u32 = @truncate(input >> 32);

    return .{ .high = high, .low = low };
}

//
// Combines two 32-bit numbers into a single 64-bit bigint.
//
fn combineBigNum(input: SplitNumber) u64 {
    return @as(u64, input.high) * (@as(u64, 1) << 32) + @as(u64, input.low);
}

//
// Recursively serializes a single merkle tree node and its children (version 5 with string table).
//
fn serializeMerkleNodeV5(node: *const MerkleNode, serializer: ISerializer, stringTable: *const std.StringHashMapUnmanaged(u32), hashTable: *const BufferMap(u32)) !void {
    // Write nodeCount
    try serializer.writeUInt32(node.nodeCount);

    // Write the hash index (instead of the hash bytes)
    if (node.hash.len != 32) {
        return errors.throwError("Invalid hash length: {d}, expected 32 bytes", .{node.hash.len});
    }
    const hashIndex = (try hashTable.get(node.hash)) orelse {
        return errors.throwError("Hash not found in hash table. This could be a bug.", .{});
    };
    try serializer.writeUInt32(hashIndex);

    // For leaf nodes, write the name index
    if (node.nodeCount == 1) {
        if (node.name == null or node.name.?.len == 0) {
            return errors.throwError("Leaf node has no name", .{});
        }
        const nameIndex = stringTable.get(node.name.?) orelse {
            return errors.throwError("name \"{s}\" not found in string table. This could be a bug.", .{node.name.?});
        };
        try serializer.writeUInt32(nameIndex);
    }

    // Recursively write children if this is not a leaf
    if (node.left) |left| {
        try serializeMerkleNodeV5(left, serializer, stringTable, hashTable);
    }
    if (node.right) |right| {
        try serializeMerkleNodeV5(right, serializer, stringTable, hashTable);
    }
}

// Not ported: serializeMerkleNode (the version 4 writer is not used; trees are always saved in the current format).

//
// Serializes the merkle tree nodes (version 5 with string table).
//
fn serializeMerkleV5(tree: *const IMerkleTree, serializer: ISerializer, stringTable: *const std.StringHashMapUnmanaged(u32), hashTable: *const BufferMap(u32)) !void {
    const merkle = tree.merkle orelse {
        // Write 0 to indicate no merkle tree
        try serializer.writeUInt32(0);
        return;
    };

    // Recursively serialize the merkle tree (root nodeCount will indicate total nodes)
    try serializeMerkleNodeV5(merkle, serializer, stringTable, hashTable);
}

// Not ported: serializeMerkle (the version 4 writer is not used; trees are always saved in the current format).

//
// Serializes the sort tree metadata and nodes (version 5 with string table).
//
fn serializeSortTreeV5(tree: *const IMerkleTree, serializer: ISerializer, stringTable: *const std.StringHashMapUnmanaged(u32), hashTable: *const BufferMap(u32)) !void {
    const sort = tree.sort orelse {
        // Write 0 to indicate no tree
        try serializer.writeUInt32(0);
        return;
    };

    // Recursively serialize the sort tree (root's nodeCount serves as the "tree exists" indicator)
    try serializeSortNodeV5(sort, serializer, stringTable, hashTable);
}

//
// Recursively serializes a single sort tree node and its children (version 5 with string table).
//
fn serializeSortNodeV5(node: *const SortNode, serializer: ISerializer, stringTable: *const std.StringHashMapUnmanaged(u32), hashTable: *const BufferMap(u32)) !void {
    // Write nodeCount
    try serializer.writeUInt32(node.nodeCount);

    if (node.nodeCount == 1) {
        // Leaf node
        if (node.name == null or node.name.?.len == 0) {
            return errors.throwError("Leaf node has no name. This could be a bug.", .{});
        }

        const contentHash = node.contentHash orelse {
            return errors.throwError("Leaf node has no content hash. This could be a bug.", .{});
        };

        // Write name index
        const nameIndex = stringTable.get(node.name.?) orelse {
            return errors.throwError("name \"{s}\" not found in string table. This could be a bug.", .{node.name.?});
        };
        try serializer.writeUInt32(nameIndex);

        // Write content hash index (instead of the hash bytes)
        const contentHashIndex = (try hashTable.get(contentHash)) orelse {
            return errors.throwError("Content hash not found in hash table. This could be a bug.", .{});
        };
        try serializer.writeUInt32(contentHashIndex);

        // Write size (only for leaf nodes)
        const splitSize = splitBigNum(node.size);
        try serializer.writeUInt32(splitSize.low);
        try serializer.writeUInt32(splitSize.high);

        // Write item metadata for leaf nodes in version 3+
        // Write lastModified timestamp (8 bytes)
        const lastModified: i64 = node.lastModified orelse 0;
        const splitLastModified = splitBigNum(@bitCast(lastModified));
        try serializer.writeUInt32(splitLastModified.low);
        if (lastModified < 0) {
            // (Zig: stands in for Buffer.writeUInt32LE, which throws for the negative high part of a date before 1970.)
            return errors.throwError("The value of \"value\" is out of range. It must be >= 0 and <= 4294967295. Received {d}", .{lastModified >> 32});
        }
        try serializer.writeUInt32(splitLastModified.high);
    }
    else {
        // Internal node - recursively serialize children
        if (node.left) |left| {
            try serializeSortNodeV5(left, serializer, stringTable, hashTable);
        }
        if (node.right) |right| {
            try serializeSortNodeV5(right, serializer, stringTable, hashTable);
        }
    }
}

//
// Collects all unique strings from the tree for the string table.
// (Zig: returns the strings in insertion order, like a JavaScript Set.)
//
fn collectStrings(allocator: std.mem.Allocator, tree: *const IMerkleTree) ![]const []const u8 {
    var strings: std.StringArrayHashMapUnmanaged(void) = .empty;

    const Collector = struct {
        // Collect from sort tree
        fn collectFromSortNode(collectorAllocator: std.mem.Allocator, collected: *std.StringArrayHashMapUnmanaged(void), node: ?*const SortNode) !void {
            const currentNode = node orelse {
                return;
            };

            if (currentNode.name) |name| {
                if (name.len > 0) {
                    try collected.put(collectorAllocator, name, {});
                }
            }

            try collectFromSortNode(collectorAllocator, collected, currentNode.left);
            try collectFromSortNode(collectorAllocator, collected, currentNode.right);
        }

        // Collect from merkle tree
        fn collectFromMerkleNode(collectorAllocator: std.mem.Allocator, collected: *std.StringArrayHashMapUnmanaged(void), node: ?*const MerkleNode) !void {
            const currentNode = node orelse {
                return;
            };

            if (currentNode.name) |name| {
                if (name.len > 0) {
                    try collected.put(collectorAllocator, name, {});
                }
            }

            try collectFromMerkleNode(collectorAllocator, collected, currentNode.left);
            try collectFromMerkleNode(collectorAllocator, collected, currentNode.right);
        }
    };

    try Collector.collectFromSortNode(allocator, &strings, tree.sort);
    try Collector.collectFromMerkleNode(allocator, &strings, tree.merkle);

    return strings.keys();
}

//
// Collects all unique hashes from the tree for the hash table.
// Returns an array of unique Buffers (hashes are 32 bytes).
//
fn collectHashes(allocator: std.mem.Allocator, tree: *const IMerkleTree) ![]const []const u8 {
    var hashSet = BufferSet.init(allocator);

    const Collector = struct {
        // Collect from sort tree (contentHash for leaf nodes)
        fn collectFromSortNode(collected: *BufferSet, node: ?*const SortNode) !void {
            const currentNode = node orelse {
                return;
            };

            if (currentNode.contentHash) |contentHash| {
                _ = try collected.add(contentHash);
            }

            try collectFromSortNode(collected, currentNode.left);
            try collectFromSortNode(collected, currentNode.right);
        }

        // Collect from merkle tree (hash for all nodes)
        fn collectFromMerkleNode(collected: *BufferSet, node: ?*const MerkleNode) !void {
            const currentNode = node orelse {
                return;
            };

            _ = try collected.add(currentNode.hash);

            try collectFromMerkleNode(collected, currentNode.left);
            try collectFromMerkleNode(collected, currentNode.right);
        }
    };

    try Collector.collectFromSortNode(&hashSet, tree.sort);
    try Collector.collectFromMerkleNode(&hashSet, tree.merkle);

    // Convert BufferSet to array
    var hashes: std.ArrayList([]const u8) = .empty;
    var hashValues = hashSet.values();
    while (hashValues.next()) |hash| {
        try hashes.append(allocator, hash);
    }
    return hashes.items;
}

//
// Serializes a merkle tree to storage.
//
// File format (version 5):
//
// Database metadata:
// - X bytes: Database metadata as BSON
//
// Tree metadata:
// - 16 bytes: UUID
//
// String table (compressed with gzip):
// - 4 bytes: compressed string table length (uint32)
// - X bytes: compressed string table data (gzip)
//   - Decompressed format:
//     - 4 bytes: string table size (number of strings, uint32)
//     - For each string:
//       - 4 bytes: string length (uint32)
//       - X bytes: string (UTF-8)
//
// Hash table (uncompressed):
// - 4 bytes: hash table size (number of hashes, uint32)
// - For each hash:
//   - 32 bytes: hash (SHA-256)
//
// Sort tree (compressed with gzip, pre-order traversal):
// - 4 bytes: compressed sort tree length (uint32)
// - X bytes: compressed sort tree data (gzip)
//   - Decompressed format:
//     - For each sort node (root's nodeCount of 0 means no tree):
//       - 4 bytes: nodeCount (uint32, 1 for leaf nodes, 0 if no tree)
//       - If leaf node (nodeCount == 1):
//         - 4 bytes: name index (uint32) - index into string table
//         - 4 bytes: content hash index (uint32) - index into hash table
//         - 8 bytes: size (uint64 split into low/high uint32s)
//         - 8 bytes: lastModified timestamp (uint64 split into low/high uint32s)
//       - If internal node (nodeCount > 1):
//         - Recursively serialize children
//       - Note: minName and size for internal nodes are recalculated during deserialization
//         (minName = name for leaf nodes, minName = left.minName for internal nodes)
//
// Merkle tree (compressed with gzip):
// - 4 bytes: compressed merkle tree length (uint32)
// - X bytes: compressed merkle tree data (gzip)
//   - Decompressed format:
//     - For each merkle node (pre-order traversal, root nodeCount of 0 means no merkle tree):
//       - 4 bytes: nodeCount (uint32, 1 for leaf nodes, 0 for no tree)
//       - 4 bytes: hash index (uint32) - index into hash table - only if nodeCount > 0
//       - If leaf node (nodeCount == 1):
//         - 4 bytes: name index (uint32) - index into string table
//
fn serializeMerkleTree(allocator: std.mem.Allocator, tree: *const IMerkleTree, serializer: ISerializer) anyerror!void {
    // Write database metadata BSON
    // (Zig: missing metadata is written as an empty document, which is what the bson library writes for undefined.)
    try serializer.writeBSON(tree.databaseMetadata orelse bson.BsonDocument.empty);

    // Write tree UUID
    const idBuffer = try parseUuid(tree.id);
    try serializer.writeBytes(&idBuffer);

    // Collect all unique strings and build string table
    const uniqueStrings = try collectStrings(allocator, tree);
    const stringArray = try allocator.dupe([]const u8, uniqueStrings);
    // Sort string table in ascending order to improve compression
    std.mem.sort([]const u8, stringArray, {}, lessThanUtf16);
    var stringTable: std.StringHashMapUnmanaged(u32) = .empty;
    for (stringArray, 0..) |str, index| {
        try stringTable.put(allocator, str, @intCast(index));
    }

    // Collect all unique hashes and build hash table
    const uniqueHashes = try collectHashes(allocator, tree);
    var hashTable = BufferMap(u32).init(allocator);
    for (uniqueHashes, 0..) |hash, index| {
        _ = try hashTable.set(hash, @intCast(index));
    }

    // Write string table (compressed for version 5)
    var stringTableSerializer = try CompressedBinarySerializer.init(allocator, serializer, 1024);
    try stringTableSerializer.writeUInt32(@intCast(stringArray.len));
    for (stringArray) |str| {
        try stringTableSerializer.writeString(str);
    }
    try stringTableSerializer.finish();

    // Write hash table (uncompressed)
    try serializer.writeUInt32(@intCast(uniqueHashes.len));
    for (uniqueHashes) |hash| {
        if (hash.len != 32) {
            return errors.throwError("Invalid hash length: {d}, expected 32 bytes", .{hash.len});
        }
        try serializer.writeBytes(hash);
    }

    // Write sort tree metadata and nodes (compressed for version 5, using string and hash indices)
    var sortTreeSerializer = try CompressedBinarySerializer.init(allocator, serializer, 1024);
    try serializeSortTreeV5(tree, sortTreeSerializer.asSerializer(), &stringTable, &hashTable);
    try sortTreeSerializer.finish();

    // Write merkle tree nodes (compressed for version 5, using string and hash indices)
    var merkleTreeSerializer = try CompressedBinarySerializer.init(allocator, serializer, 1024);
    try serializeMerkleV5(tree, merkleTreeSerializer.asSerializer(), &stringTable, &hashTable);
    try merkleTreeSerializer.finish();
}

// Not ported: rebuildTree (only used by psi upgrade).

//
// Recursively deserializes a single merkle tree node and its children (version 5 with string and hash tables).
//
fn deserializeMerkleNodeV5(allocator: std.mem.Allocator, deserializer: IDeserializer, stringTable: []const []const u8, hashTable: []const []const u8) !*MerkleNode {
    // Read nodeCount
    const nodeCount = try deserializer.readUInt32();

    // Read this node's hash index
    const hashIndex = try deserializer.readUInt32();
    if (hashIndex >= hashTable.len) {
        return errors.throwError("Hash index {d} is out of bounds for hash table of size {d}", .{ hashIndex, hashTable.len });
    }
    const hash = hashTable[hashIndex];

    const node = try allocator.create(MerkleNode);
    if (nodeCount == 1) {
        // Leaf node - read name index
        const nameIndex = try deserializer.readUInt32();
        if (nameIndex >= stringTable.len) {
            return errors.throwError("name index {d} is out of bounds for string table of size {d}", .{ nameIndex, stringTable.len });
        }
        const name = stringTable[nameIndex];
        node.* = .{ .hash = hash, .nodeCount = nodeCount, .name = name };
        return node;
    }
    else {
        // Internal node - recursively deserialize children
        const left = try deserializeMerkleNodeV5(allocator, deserializer, stringTable, hashTable);
        const right = try deserializeMerkleNodeV5(allocator, deserializer, stringTable, hashTable);

        node.* = .{
            .hash = hash,
            .nodeCount = nodeCount,
            .left = left,
            .right = right,
        };
        return node;
    }
}

//
// Recursively deserializes a single merkle tree node and its children (version 4 and earlier).
//
fn deserializeMerkleNode(allocator: std.mem.Allocator, deserializer: IDeserializer) !*MerkleNode {
    // Read nodeCount
    const nodeCount = try deserializer.readUInt32();

    // Read this node's hash
    const hash = try deserializer.readBytes(32);

    const node = try allocator.create(MerkleNode);
    if (nodeCount == 1) {
        // Leaf node - read name
        const name = try deserializer.readString();
        node.* = .{ .hash = hash, .nodeCount = nodeCount, .name = name };
        return node;
    }
    else {
        // Internal node - recursively deserialize children
        const left = try deserializeMerkleNode(allocator, deserializer);
        const right = try deserializeMerkleNode(allocator, deserializer);

        node.* = .{
            .hash = hash,
            .nodeCount = nodeCount,
            .left = left,
            .right = right,
        };
        return node;
    }
}

//
// Deserializes the merkle tree nodes (version 5 with string and hash tables).
//
fn deserializeMerkleV5(allocator: std.mem.Allocator, deserializer: IDeserializer, stringTable: []const []const u8, hashTable: []const []const u8) !?*MerkleNode {
    // Read the root node's nodeCount (0 means no merkle tree)
    const nodeCount = try deserializer.readUInt32();
    if (nodeCount == 0) {
        // No merkle tree was serialized
        return null;
    }

    // Read the root node's hash index
    const hashIndex = try deserializer.readUInt32();
    if (hashIndex >= hashTable.len) {
        return errors.throwError("Hash index {d} is out of bounds for hash table of size {d}", .{ hashIndex, hashTable.len });
    }
    const hash = hashTable[hashIndex];

    const node = try allocator.create(MerkleNode);
    if (nodeCount == 1) {
        // Root is a leaf node - read name index
        const nameIndex = try deserializer.readUInt32();
        if (nameIndex >= stringTable.len) {
            return errors.throwError("name index {d} is out of bounds for string table of size {d}", .{ nameIndex, stringTable.len });
        }
        const name = stringTable[nameIndex];
        node.* = .{ .hash = hash, .nodeCount = nodeCount, .name = name };
        return node;
    }
    else {
        // Root is an internal node - recursively deserialize children
        const left = try deserializeMerkleNodeV5(allocator, deserializer, stringTable, hashTable);
        const right = try deserializeMerkleNodeV5(allocator, deserializer, stringTable, hashTable);

        node.* = .{
            .hash = hash,
            .nodeCount = nodeCount,
            .left = left,
            .right = right,
        };
        return node;
    }
}

//
// Deserializes the merkle tree nodes (version 4 and earlier).
//
fn deserializeMerkle(allocator: std.mem.Allocator, deserializer: IDeserializer) !?*MerkleNode {
    // Read the root node's nodeCount (0 means no merkle tree)
    const nodeCount = try deserializer.readUInt32();
    if (nodeCount == 0) {
        // No merkle tree was serialized
        return null;
    }

    // Read the root node's hash
    const hash = try deserializer.readBytes(32);

    const node = try allocator.create(MerkleNode);
    if (nodeCount == 1) {
        // Root is a leaf node - read name
        const name = try deserializer.readString();
        node.* = .{ .hash = hash, .nodeCount = nodeCount, .name = name };
        return node;
    }
    else {
        // Root is an internal node - recursively deserialize children
        const left = try deserializeMerkleNode(allocator, deserializer);
        const right = try deserializeMerkleNode(allocator, deserializer);

        node.* = .{
            .hash = hash,
            .nodeCount = nodeCount,
            .left = left,
            .right = right,
        };
        return node;
    }
}

//
// Recursively deserializes a single sort tree node and its children (version 5 with string and hash tables).
//
fn deserializeSortNodeV5(allocator: std.mem.Allocator, deserializer: IDeserializer, stringTable: []const []const u8, hashTable: []const []const u8) !?*SortNode {
    // Read node metadata
    const nodeCount = try deserializer.readUInt32();
    if (nodeCount == 0) {
        // Root node with nodeCount of 0 means empty tree
        return null;
    }

    const node = try allocator.create(SortNode);
    if (nodeCount == 1) {
        // This is a leaf node

        // Read name index
        const nameIndex = try deserializer.readUInt32();
        if (nameIndex >= stringTable.len) {
            return errors.throwError("name index {d} is out of bounds for string table of size {d}", .{ nameIndex, stringTable.len });
        }
        const name = stringTable[nameIndex];

        // Read content hash index
        const contentHashIndex = try deserializer.readUInt32();
        if (contentHashIndex >= hashTable.len) {
            return errors.throwError("Content hash index {d} is out of bounds for hash table of size {d}", .{ contentHashIndex, hashTable.len });
        }
        const contentHash = hashTable[contentHashIndex];

        // Read size (only serialized for leaf nodes)
        const sizeLow = try deserializer.readUInt32();
        const sizeHigh = try deserializer.readUInt32();
        const size = combineBigNum(.{ .low = sizeLow, .high = sizeHigh });

        const lastModifiedLow = try deserializer.readUInt32();
        const lastModifiedHigh = try deserializer.readUInt32();
        const lastModifiedTimestamp = combineBigNum(.{ .low = lastModifiedLow, .high = lastModifiedHigh });
        const lastModified: ?i64 = if (lastModifiedTimestamp > 0) @bitCast(lastModifiedTimestamp) else null;

        // For leaf nodes, minName equals name
        node.* = .{
            .contentHash = contentHash,
            .name = name,
            .nodeCount = nodeCount,
            .leafCount = 1,
            .size = size,
            .lastModified = lastModified,
            .minName = name,
        };
        return node;
    }
    else {
        // This is an internal node - recursively read children
        const left = try deserializeSortNodeV5(allocator, deserializer, stringTable, hashTable);
        const right = try deserializeSortNodeV5(allocator, deserializer, stringTable, hashTable);

        // Recalculate size from children (size is not serialized for internal nodes)
        const size = (if (left) |leftNode| leftNode.size else 0) + (if (right) |rightNode| rightNode.size else 0);

        node.* = .{
            .nodeCount = nodeCount,
            .leafCount = left.?.leafCount + right.?.leafCount,
            .size = size,
            .minName = left.?.minName,
            .left = left,
            .right = right,
        };
        return node;
    }
}

//
// Recursively deserializes a single sort tree node and its children (version 4 and earlier).
//
fn deserializeSortNode(allocator: std.mem.Allocator, deserializer: IDeserializer) !?*SortNode {
    // Read node metadata
    const nodeCount = try deserializer.readUInt32();
    if (nodeCount == 0) {
        // Root node with nodeCount of 0 means empty tree
        return null;
    }

    _ = try deserializer.readUInt32(); // Drop the leaf count.
    const sizeLow = try deserializer.readUInt32();
    const sizeHigh = try deserializer.readUInt32();
    const size = combineBigNum(.{ .low = sizeLow, .high = sizeHigh });

    const node = try allocator.create(SortNode);
    if (nodeCount == 1) {
        // This is a leaf node
        const nameLength = try deserializer.readUInt32(); //todo: Use readString.
        const nameBytes = try deserializer.readBytes(nameLength);
        const name = nameBytes;

        const contentHash = try deserializer.readBytes(32);

        const lastModifiedLow = try deserializer.readUInt32();
        const lastModifiedHigh = try deserializer.readUInt32();
        const lastModifiedTimestamp = combineBigNum(.{ .low = lastModifiedLow, .high = lastModifiedHigh });
        const lastModified: ?i64 = if (lastModifiedTimestamp > 0) @bitCast(lastModifiedTimestamp) else null;

        node.* = .{
            .contentHash = contentHash,
            .name = name,
            .nodeCount = nodeCount,
            .leafCount = 1,
            .size = size,
            .lastModified = lastModified,
            .minName = name,
        };
        return node;
    }
    else {
        // This is an internal node - recursively read children
        const left = try deserializeSortNode(allocator, deserializer);
        const right = try deserializeSortNode(allocator, deserializer);
        node.* = .{
            .nodeCount = nodeCount,
            .leafCount = left.?.leafCount + right.?.leafCount,
            .size = size,
            .minName = left.?.minName,
            .left = left,
            .right = right,
        };
        return node;
    }
}

//
// Deserializes the sort tree metadata and nodes (version 5 with string table).
//
fn deserializeSortTreeV5(allocator: std.mem.Allocator, deserializer: IDeserializer, stringTable: []const []const u8, hashTable: []const []const u8) !?*SortNode {
    // Deserialize the root node (may return undefined if nodeCount is 0)
    return deserializeSortNodeV5(allocator, deserializer, stringTable, hashTable);
}

//
// Deserializes the sort tree metadata and nodes (version 4 and earlier).
//
fn deserializeSortTree(allocator: std.mem.Allocator, deserializer: IDeserializer) !?*SortNode {
    // Deserialize the root node (may return undefined if nodeCount is 0)
    return deserializeSortNode(allocator, deserializer);
}

//
// Deserializer function for merkle tree (version 6)
//
fn deserializeMerkleTreeV6(allocator: std.mem.Allocator, context: void, deserializer: IDeserializer) anyerror!IMerkleTree {
    _ = context;
    const databaseMetadata = try deserializer.readBSON();

    const uuidBytes = try deserializer.readBytes(16);
    const id = try stringifyUuid(allocator, uuidBytes);

    var stringTableDeserializer = try CompressedBinaryDeserializer.init(allocator, deserializer);
    const stringTableSize = try stringTableDeserializer.readUInt32();
    var stringTable: std.ArrayList([]const u8) = .empty;
    var stringIndex: u32 = 0;
    while (stringIndex < stringTableSize) : (stringIndex += 1) {
        const str = try stringTableDeserializer.readString();
        try stringTable.append(allocator, str);
    }

    const hashTableSize = try deserializer.readUInt32();
    var hashTable: std.ArrayList([]const u8) = .empty;
    var hashIndex: u32 = 0;
    while (hashIndex < hashTableSize) : (hashIndex += 1) {
        const hash = try deserializer.readBytes(32);
        try hashTable.append(allocator, hash);
    }

    var sortTreeDeserializer = try CompressedBinaryDeserializer.init(allocator, deserializer);
    const sort = try deserializeSortTreeV5(allocator, sortTreeDeserializer.asDeserializer(), stringTable.items, hashTable.items);

    var merkleTreeDeserializer = try CompressedBinaryDeserializer.init(allocator, deserializer);
    const merkle = try deserializeMerkleV5(allocator, merkleTreeDeserializer.asDeserializer(), stringTable.items, hashTable.items);

    return .{
        .id = id,
        .sort = sort,
        .dirty = false,
        .merkle = merkle,
        .databaseMetadata = databaseMetadata,
        .version = 6,
    };
}

//
// Deserializer function for merkle tree (version 5)
//
fn deserializeMerkleTreeV5(allocator: std.mem.Allocator, context: void, deserializer: IDeserializer) anyerror!IMerkleTree {
    _ = context;
    // Read database metadata BSON
    const databaseMetadata = try deserializer.readBSON();

    // Read tree UUID
    const uuidBytes = try deserializer.readBytes(16);
    const id = try stringifyUuid(allocator, uuidBytes);

    // Read string table (compressed for version 5)
    var stringTableDeserializer = try CompressedBinaryDeserializer.init(allocator, deserializer);
    const stringTableSize = try stringTableDeserializer.readUInt32();
    var stringTable: std.ArrayList([]const u8) = .empty;
    var stringIndex: u32 = 0;
    while (stringIndex < stringTableSize) : (stringIndex += 1) {
        const str = try stringTableDeserializer.readString();
        try stringTable.append(allocator, str);
    }

    // Read hash table (uncompressed)
    const hashTableSize = try deserializer.readUInt32();
    var hashTable: std.ArrayList([]const u8) = .empty;
    var hashIndex: u32 = 0;
    while (hashIndex < hashTableSize) : (hashIndex += 1) {
        const hash = try deserializer.readBytes(32);
        try hashTable.append(allocator, hash);
    }

    // Read sort tree metadata and nodes (compressed for version 5, using string and hash tables)
    var sortTreeDeserializer = try CompressedBinaryDeserializer.init(allocator, deserializer);
    const sort = try deserializeSortTreeV5(allocator, sortTreeDeserializer.asDeserializer(), stringTable.items, hashTable.items);

    // Read merkle tree nodes (compressed for version 5, using string and hash tables)
    var merkleTreeDeserializer = try CompressedBinaryDeserializer.init(allocator, deserializer);
    const merkle = try deserializeMerkleV5(allocator, merkleTreeDeserializer.asDeserializer(), stringTable.items, hashTable.items);

    return .{
        .id = id,
        .sort = sort,
        .dirty = false,
        .merkle = merkle,
        .databaseMetadata = databaseMetadata,
        .version = 5,
    };
}

//
// Deserializer function for merkle tree (version 4)
//
fn deserializeMerkleTreeV4(allocator: std.mem.Allocator, context: void, deserializer: IDeserializer) anyerror!IMerkleTree {
    _ = context;
    // Read database metadata BSON
    const databaseMetadata = try deserializer.readBSON();

    // Read tree UUID
    const uuidBytes = try deserializer.readBytes(16);
    const id = try stringifyUuid(allocator, uuidBytes);

    // Read sort tree metadata and nodes
    const sort = try deserializeSortTree(allocator, deserializer);

    // Read merkle tree nodes
    const merkle = try deserializeMerkle(allocator, deserializer);

    return .{
        .id = id,
        .sort = sort,
        .dirty = false,
        .merkle = merkle,
        .databaseMetadata = databaseMetadata,
        .version = 4,
    };
}

//
// Deserializer function for merkle tree (version 3)
//
fn deserializeMerkleTreeV3(allocator: std.mem.Allocator, context: void, deserializer: IDeserializer) anyerror!IMerkleTree {
    _ = context;
    // Read database metadata BSON for version 3+
    const databaseMetadata = try deserializer.readBSON();

    // Read tree metadata fields
    const uuidBytes = try deserializer.readBytes(16);
    const uuid = try stringifyUuid(allocator, uuidBytes);

    const totalNodes = try deserializer.readUInt32();

    _ = try deserializer.readUInt32();
    _ = try deserializer.readUInt32();
    _ = try deserializer.readUInt32();

    // Read all nodes
    var nodes: std.ArrayList(FlatSortNode) = .empty;

    var nodeIndex: u32 = 0;
    while (nodeIndex < totalNodes) : (nodeIndex += 1) {
        // Read hash
        const hash = try deserializer.readBytes(32);

        // Read nodeCount
        const nodeCount = try deserializer.readUInt32();

        // Read leafCount
        const leafCount = try deserializer.readUInt32();

        // Read tree size.
        const sizeLow = try deserializer.readUInt32();
        const sizeHigh = try deserializer.readUInt32();
        const size = combineBigNum(.{ .low = sizeLow, .high = sizeHigh });

        // Read name if present
        const nameLength = try deserializer.readUInt32();

        var name: ?[]const u8 = null;
        var lastModified: ?i64 = null;

        if (nameLength > 0) {
            const nameBytes = try deserializer.readBytes(nameLength);
            name = nameBytes;

            // Read item metadata for leaf nodes in version 3+
            // Read lastModified timestamp (8 bytes)
            const lastModifiedLow = try deserializer.readUInt32();
            const lastModifiedHigh = try deserializer.readUInt32();
            const lastModifiedTimestamp = combineBigNum(.{ .low = lastModifiedLow, .high = lastModifiedHigh });
            if (lastModifiedTimestamp > 0) {
                lastModified = @bitCast(lastModifiedTimestamp);
            }
        }

        _ = try deserializer.readUInt8(); // Discard isDeleted flag.

        // Create node
        try nodes.append(allocator, .{
            .contentHash = if (nodeCount == 1) hash else null,
            .name = name,
            .nodeCount = nodeCount,
            .leafCount = leafCount,
            .size = size,
            .lastModified = lastModified,
        });
    }

    const sort = try arrayToBinaryTree(allocator, nodes.items);
    return .{
        .id = uuid,
        .sort = sort,
        .dirty = false,
        .merkle = try buildMerkleTree(allocator, sort), //TODO: Load the merkle tree from disk.
        .databaseMetadata = databaseMetadata,
        .version = 3,
    };
}

//
// Deserializer function for merkle tree (version 2)
//
fn deserializeMerkleTreeV2(allocator: std.mem.Allocator, context: void, deserializer: IDeserializer) anyerror!IMerkleTree {
    _ = context;

    // Read tree metadata fields
    const uuidBytes = try deserializer.readBytes(16);
    const uuid = try stringifyUuid(allocator, uuidBytes);

    const totalNodes = try deserializer.readUInt32();

    _ = try deserializer.readUInt32();
    _ = try deserializer.readUInt32();
    _ = try deserializer.readUInt32();
    _ = try deserializer.readUInt32(); // Created at low removed in v3.
    _ = try deserializer.readUInt32(); // Created at high removed in v3.
    _ = try deserializer.readUInt32(); // Modified at low removed in v3.
    _ = try deserializer.readUInt32(); // Modified at high removed in v3.

    // Read all nodes
    var nodes: std.ArrayList(FlatSortNode) = .empty;

    var nodeIndex: u32 = 0;
    while (nodeIndex < totalNodes) : (nodeIndex += 1) {
        // Read hash
        const hash = try deserializer.readBytes(32);

        // Read nodeCount
        const nodeCount = try deserializer.readUInt32();

        // Read leafCount
        const leafCount = try deserializer.readUInt32();

        // Read tree size.
        const sizeLow = try deserializer.readUInt32();
        const sizeHigh = try deserializer.readUInt32();
        const size = combineBigNum(.{ .low = sizeLow, .high = sizeHigh });

        // Read name if present
        const nameLength = try deserializer.readUInt32();

        var name: ?[]const u8 = null;
        const lastModified: ?i64 = null;

        if (nameLength > 0) {
            const nameBytes = try deserializer.readBytes(nameLength);
            name = nameBytes;
        }

        _ = try deserializer.readUInt8(); // Discard isDeleted flag.

        // Create node
        try nodes.append(allocator, .{
            .contentHash = if (nodeCount == 1) hash else null,
            .name = name,
            .nodeCount = nodeCount,
            .leafCount = leafCount,
            .size = size,
            .lastModified = lastModified,
        });
    }

    const sort = try arrayToBinaryTree(allocator, nodes.items);
    return .{
        .id = uuid,
        .sort = sort,
        .dirty = false,
        .merkle = try buildMerkleTree(allocator, sort), //TODO: Load the merkle tree from disk.
        .databaseMetadata = null,
        .version = 2,
    };
}

//
// Saves a merkle tree to storage (v6 layout with type code and checksum).
// (Zig: the TypeScript default typeCode is 'FTRE'; callers pass it explicitly.)
//
pub fn saveTree(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, tree: *const IMerkleTree, storage: IStorage, typeCode: []const u8) !void {

    if (tree.dirty) {
        return errors.throwError("Tree is dirty. Cannot save. Make sure to rebuild the tree before saving.", .{});
    }

    try serialization.save(
        allocator,
        io,
        storage,
        filePath,
        tree,
        CURRENT_DATABASE_VERSION,
        typeCode,
        serializeMerkleTree,
    );
}

//
// Loads only the version number from a merkle tree file without loading the entire tree.
// This is useful for version compatibility checks before full database loading.
// Uses the serialization library so the version header is read in one place.
//
pub fn loadTreeVersion(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, storage: IStorage) ?u32 {
    return serialization.loadVersion(allocator, io, storage, filePath);
}

//
// The deserializers for every supported version of the tree file (TypeScript: the `deserializers` object in loadTree).
//
const tree_deserializers = [_]serialization.DeserializerEntry(IMerkleTree, void){
    .{ .version = 6, .deserializer = deserializeMerkleTreeV6 },
    .{ .version = 5, .deserializer = deserializeMerkleTreeV5 },
    .{ .version = 4, .deserializer = deserializeMerkleTreeV4 },
    .{ .version = 3, .deserializer = deserializeMerkleTreeV3 },
    .{ .version = 2, .deserializer = deserializeMerkleTreeV2 },
};

//
// Loads a merkle tree from storage (null when the file does not exist).
// (Zig: the TypeScript default typeCode is 'FTRE'; callers pass it explicitly.)
//
pub fn loadTree(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, storage: IStorage, typeCode: []const u8) !?IMerkleTree {
    return serialization.load(
        IMerkleTree,
        allocator,
        io,
        storage,
        filePath,
        typeCode,
        {},
        &tree_deserializers,
    );
}

//
// Delete an item node from the Merkle tree, actually removing it from the tree structure
// This function properly removes the node and rebalances the tree
//
// @param merkleTree The Merkle tree containing the item
// @param name The name of the item to delete
//
pub fn deleteItem(
    allocator: std.mem.Allocator,
    merkleTree: *IMerkleTree,
    name: []const u8,
) !void {
    merkleTree.sort = try _deleteNode(allocator, merkleTree.sort, name);
    merkleTree.dirty = true; // Mark the tree as dirty so it will be rebuilt later.
}

//
// Internal function to delete a node from the tree and return the new root
// This handles the complex logic of removing a node while maintaining tree structure
//
fn _deleteNode(allocator: std.mem.Allocator, node: ?*SortNode, name: []const u8) !?*SortNode {
    const currentNode = node orelse {
        return null;
    };

    // If this is a leaf node, check if it's the target
    if (currentNode.nodeCount == 1) {
        if (currentNode.name != null and std.mem.eql(u8, currentNode.name.?, name)) {
            return null; // Signal to parent that this node should be removed
        }
        return currentNode; // Not the target, return unchanged
    }

    const left = currentNode.left orelse {
        return errors.throwError("Invalid tree structure", .{});
    };
    const right = currentNode.right orelse {
        return errors.throwError("Invalid tree structure", .{});
    };

    var newLeft = left;
    var newRight = right;
    var nodeDeleted = false;

    // Check if the target is in the left subtree
    if (compareNames(name, right.minName) < 0) {
        const result = try _deleteNode(allocator, left, name) orelse {
            // The left child was deleted, promote the right child
            return right;
        };
        newLeft = result;
        nodeDeleted = true;
    }
    else {
        // Check if the target is in the right subtree
        const result = try _deleteNode(allocator, right, name) orelse {
            // The right child was deleted, promote the left child
            return left;
        };
        newRight = result;
        nodeDeleted = true;
    }

    if (!nodeDeleted) {
        return currentNode; // Node not found
    }

    // Create new node with updated children and recalculated properties
    const newNode = try allocator.create(SortNode);
    newNode.* = currentNode.*;
    newNode.left = newLeft;
    newNode.right = newRight;
    newNode.nodeCount = 1 + newLeft.nodeCount + newRight.nodeCount;
    newNode.leafCount = newLeft.leafCount + newRight.leafCount;
    newNode.size = newLeft.size + newRight.size;
    newNode.minName = newLeft.minName;

    // Rebalance the tree after deletion
    return try rebalanceTree(allocator, newNode);
}

//
// Prunes nodes from a merkle tree by removing all files represented by the given MerkleNode roots.
// This iterates leaves on each MerkleNode to find file names, then removes those files from the sort tree.
//
// @param merkleTree The merkle tree to prune
// @param nodesToPrune Array of MerkleNode roots representing subtrees to remove
// @returns Array of file names that were pruned
//
pub fn pruneTree(
    allocator: std.mem.Allocator,
    merkleTree: *IMerkleTree,
    nodesToPrune: []const *MerkleNode,
) ![]const []const u8 {
    var prunedFiles: std.ArrayList([]const u8) = .empty;

    // Iterate leaves on each MerkleNode and remove files from the sort tree
    for (nodesToPrune) |node| {
        var leaves = iterateLeaves(MerkleNode, allocator, node);
        while (try leaves.next()) |leaf| {
            if (leaf.name) |leafName| {
                if (leafName.len > 0) {
                    merkleTree.sort = try _deleteNode(allocator, merkleTree.sort, leafName);
                    try prunedFiles.append(allocator, leafName);
                }
            }
        }
    }

    // Mark the merkle tree as dirty so it will be rebuilt later
    if (prunedFiles.items.len > 0) {
        merkleTree.dirty = true;
    }

    return prunedFiles.items;
}

// Not ported: deleteItems (only used by tests, not by psi replicate or psi verify).

//
// Checks a UUID string like the `uuid` package's `validate` (the regex in uuid/dist/cjs/regex.js).
// (No TypeScript counterpart in this package: the TypeScript code calls the third-party `uuid` package.)
//
fn validateUuid(text: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(text, "00000000-0000-0000-0000-000000000000")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(text, "ffffffff-ffff-ffff-ffff-ffffffffffff")) {
        return true;
    }
    if (text.len != 36) {
        return false;
    }
    for (text, 0..) |character, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (character != '-') {
                return false;
            }
        }
        else if (!std.ascii.isHex(character)) {
            return false;
        }
    }
    if (text[14] < '1' or text[14] > '8') {
        return false;
    }
    const variant = std.ascii.toLower(text[19]);
    return variant == '8' or variant == '9' or variant == 'a' or variant == 'b';
}

//
// Converts a UUID string to its 16 bytes (the `uuid` package's `parse`, which throws 'Invalid UUID').
// (No TypeScript counterpart in this package.)
//
pub fn parseUuid(text: []const u8) errors.ThrownError![16]u8 {
    if (!validateUuid(text)) {
        return errors.throwError("Invalid UUID", .{});
    }
    var bytes: [16]u8 = undefined;
    var byteIndex: usize = 0;
    var textIndex: usize = 0;
    while (byteIndex < 16) {
        if (text[textIndex] == '-') {
            textIndex += 1;
            continue;
        }
        bytes[byteIndex] = std.fmt.parseInt(u8, text[textIndex .. textIndex + 2], 16) catch unreachable;
        byteIndex += 1;
        textIndex += 2;
    }
    return bytes;
}

//
// Converts 16 UUID bytes to the lowercase UUID string (the `uuid` package's `stringify`, which throws
// 'Stringified UUID is invalid'). (No TypeScript counterpart in this package.)
//
pub fn stringifyUuid(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(bytes[0..16].*, .lower);
    const text = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
    if (!validateUuid(text)) {
        return errors.throwError("Stringified UUID is invalid", .{});
    }
    return text;
}
