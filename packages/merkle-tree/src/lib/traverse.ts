import { INode } from "./merkle-tree";

/**
 * Generic tree traversal function that calls a callback for each node.
 * The callback can return false to stop traversal early.
 */
export function traverseTreeSync<NodeT>(node: INode<NodeT> | undefined, callback: (node: NodeT) => boolean): void {
    if (!node) {
        return;
    }
    
    if (!callback(node as NodeT)) {
        return; // Stop if callback returns false
    }
    
    traverseTreeSync<NodeT>(node.left, callback);
    traverseTreeSync<NodeT>(node.right, callback);
}

/**
 * Generic async tree traversal function that calls an async callback for each node.
 * The callback can return false to stop traversal early.
 */
export async function traverseTreeAsync<NodeT>(node: INode<NodeT> | undefined, callback: (node: NodeT) => Promise<boolean>): Promise<void> {
    if (!node) {
        return;
    }
    
    if (!await callback(node as NodeT)) {
        return; // Stop if callback returns false
    }
    
    await traverseTreeAsync<NodeT>(node.left, callback);
    await traverseTreeAsync<NodeT>(node.right, callback);
}
