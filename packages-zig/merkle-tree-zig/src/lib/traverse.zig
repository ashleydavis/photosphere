//
// (NodeT is any node struct with `left` and `right` fields of type ?*NodeT.
// The callback receives a caller supplied `context`.)
//

const ILog = @import("utils-zig").log.ILog;

//
// Generic tree traversal function that calls a callback for each node.
// The callback can return false to stop traversal early.
// (The callback may fail; its error stops the traversal and is returned.)
//
pub fn traverseTreeSync(comptime NodeT: type, node: ?*NodeT, context: anytype, callback: *const fn (@TypeOf(context), *NodeT) anyerror!bool) anyerror!void {
    const currentNode = node orelse {
        return;
    };

    if (!try callback(context, currentNode)) {
        return; // Stop if callback returns false
    }

    try traverseTreeSync(NodeT, currentNode.left, context, callback);
    try traverseTreeSync(NodeT, currentNode.right, context, callback);
}

//
// Generic async tree traversal function that calls an async callback for each node.
// The callback can return false to stop traversal early.
// (Zig: the callback is a blocking function that may fail; its error stops the traversal and is returned. It is given the log the
// traversal is given.)
//
pub fn traverseTreeAsync(comptime NodeT: type, node: ?*NodeT, log: ILog, context: anytype, callback: *const fn (@TypeOf(context), ILog, *NodeT) anyerror!bool) anyerror!void {
    const currentNode = node orelse {
        return;
    };

    if (!try callback(context, log, currentNode)) {
        return; // Stop if callback returns false
    }

    try traverseTreeAsync(NodeT, currentNode.left, log, context, callback);
    try traverseTreeAsync(NodeT, currentNode.right, log, context, callback);
}
