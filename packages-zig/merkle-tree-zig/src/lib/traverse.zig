//
// (Zig: NodeT is any node struct with `left` and `right` fields of type ?*NodeT, the Zig form of INode<NodeT>.
// The callback receives a caller supplied `context` in place of the variables a TypeScript closure captures.)
//

// Not ported: traverseTreeSync (not reached by psi replicate or psi verify)

//
// Generic async tree traversal function that calls an async callback for each node.
// The callback can return false to stop traversal early.
// (Zig: the callback is a blocking function that may fail; its error stops the traversal and is returned.)
//
pub fn traverseTreeAsync(comptime NodeT: type, node: ?*NodeT, context: anytype, callback: *const fn (@TypeOf(context), *NodeT) anyerror!bool) anyerror!void {
    const currentNode = node orelse {
        return;
    };

    if (!try callback(context, currentNode)) {
        return; // Stop if callback returns false
    }

    try traverseTreeAsync(NodeT, currentNode.left, context, callback);
    try traverseTreeAsync(NodeT, currentNode.right, context, callback);
}
