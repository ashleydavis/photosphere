import { BufferMap } from './buffer-map';
import { MerkleNode } from './merkle-tree';

export interface MerkleTreeDiff {
    identical: boolean;
    onlyInTree1: MerkleNode[];
    onlyInTree2: MerkleNode[];
}

/**
 * Processes remaining nodes after the main breadth-first traversal completes.
 * For hashes in nodes that match mapB (count > 0), decrements the count.
 * For internal nodes that don't match, recursively checks their leaves
 * to handle duplicate files correctly.
 * 
 * @internal - Exported for testing purposes only
 */
export function processRemainingNodes(nodes: MerkleNode[], mapB: BufferMap<number>, onlyInTree1: MerkleNode[]): void {
    for (const nodeA of nodes) {
        if (nodeA.nodeCount === 1) {
            // Leaf node - check against map
            const countB = mapB.get(nodeA.hash);
            if (countB === undefined || countB === 0) {
                // This leaf hash doesn't exist in tree B or has been fully matched
                onlyInTree1.push(nodeA);
            }
            else {
                // Decrement count for this match
                // This means this leaf in tree A matches a leaf in tree B
                // Note: We match by hash, not by name, so duplicate files with the same hash
                // will match against each other correctly
                mapB.set(nodeA.hash, countB - 1);
            }
        }
        else {
            // Internal node - check against map
            const countB = mapB.get(nodeA.hash);
            if (countB !== undefined && countB > 0) {
                // This internal node matches - decrement count and skip children
                mapB.set(nodeA.hash, countB - 1);
            }
            else {
                // This internal node doesn't match - expand it to check its children individually
                // This is necessary to detect duplicate files correctly
                if (nodeA.left && nodeA.right) {
                    processRemainingNodes([nodeA.left, nodeA.right], mapB, onlyInTree1);
                }
                else if (nodeA.left) {
                    throw new Error('Invalid tree structure: nodeA has a left child but no right child');
                }
                else if (nodeA.right) {
                    throw new Error('Invalid tree structure: nodeA has a right child but no left child');
                }
                else {
                    // This shouldn't happen for an internal node, but handle it
                    onlyInTree1.push(nodeA);
                }
            }
        }
    }
}

/**
 * Efficiently finds differences between two Merkle trees by comparing hashes.
 * Uses lazy expansion of tree B while traversing tree A breadth-first.
 * When a node's hash from A is found anywhere in B, both subtrees are identical and skipped.
 * 
 * @param treeA - The first Merkle tree root
 * @param treeB - The second Merkle tree root  
 * @returns Nodes that are different or new in treeA compared to treeB
 */
export function findDifferingNodes(treeA: MerkleNode, treeB: MerkleNode): MerkleNode[] {
    
    // Map of hash counts from tree B (lazily populated)
    // Tracks how many times each hash appears in tree B
    const mapB = new BufferMap<number>();
    
    // Queue for traversing tree A breadth-first
    let queueA: MerkleNode[] = [treeA];
    
    // Queue for expanding tree B level by level
    let queueB: MerkleNode[] = [treeB];
    
    while (queueA.length > 0 && queueB.length > 0) {
        // Expand the next level of tree B into the map.
        if (queueB.length > 0) {
            const currentLevelB = queueB;
            queueB = [];

            for (const nodeB of currentLevelB) {
                // Track hash counts
                const currentCount = mapB.get(nodeB.hash) || 0;
                mapB.set(nodeB.hash, currentCount + 1);

                if (nodeB.left && nodeB.right) {
                    // Queue children of nodeB to further expand the maps on the next iteration.
                    queueB.push(nodeB.left);
                    queueB.push(nodeB.right);
                }
                else if (nodeB.left) {
                    throw new Error('Invalid tree structure: nodeB has a left child but no right child');
                }
                else if (nodeB.right) {
                    throw new Error('Invalid tree structure: nodeB has a right child but no left child');
                }
                else {
                    // nodeB is a leaf node, at this point we have worked our way through tree B.
                }
            }
        }

        const currentLevelA = queueA; // Process the current level of tree A.
        queueA = []; // Clear the queue for the next level.

        for (const nodeA of currentLevelA) {
            // Check if this node exists in tree B
            if (nodeA.nodeCount === 1) {
                // Leaf node - match against map
                const countB = mapB.get(nodeA.hash);
                if (countB !== undefined && countB > 0) {
                    // Decrement count - this leaf hash has been matched once
                    mapB.set(nodeA.hash, countB - 1);
                    // Don't add children (there are none for leaf nodes)
                    continue;
                }
            }
            
            // For internal nodes, always expand them to check leaves individually
            // This ensures duplicate file counts are handled correctly.
            // Note: This is slower than matching internal nodes directly, but necessary
            // for correctness when duplicate files exist.
            if (nodeA.left && nodeA.right) {
                // Queue children of nodeA to check against expanded maps in next iteration.
                queueA.push(nodeA.left);
                queueA.push(nodeA.right);
            }
            else if (nodeA.left) {
                throw new Error('Invalid tree structure: nodeA has a left child but no right child');
            }
            else if (nodeA.right) {
                throw new Error('Invalid tree structure: nodeA has a right child but no left child');
            }
            else {
                // This is a leaf node, requeue it to check against the expanded maps in next iteration.
                queueA.push(nodeA);
            }
        }
    }

    const onlyInTree1: MerkleNode[] = [];

    // Process any remaining nodes in queueA after the main loop completes
    if (queueA.length > 0) {
        processRemainingNodes(queueA, mapB, onlyInTree1);
    }   
  
    return onlyInTree1;
}

/**
 * Finds differences between two Merkle trees by running the comparison both ways.
 */
export function findMerkleTreeDifferences(
    tree1: MerkleNode | undefined,
    tree2: MerkleNode | undefined
): MerkleTreeDiff {

    if (!tree1) {
        if (!tree2) {
            // Empty trees are considered identical.        
            return {
                identical: true,
                onlyInTree1: [],
                onlyInTree2: []
            };
        }
        else {
            // Tree1 is empty and tree2 is not empty.
            return {
                identical: false,
                onlyInTree1: [],
                onlyInTree2: [tree2] // The entire tree2 is only in tree2.
            };
        }        
    }
    else {
        if (!tree2) {
            // Tree1 is not empty and tree2 is empty.
            return {
                identical: false,
                onlyInTree1: [tree1], // The entire tree1 is only in tree1.
                onlyInTree2: []
            };
        }
        else {
            // Both trees are not empty, so we need to compare the trees.
        }
    }
    
    // Quick check: if root hashes are identical, trees are identical
    if (tree1.hash.equals(tree2.hash)) {
        return {
            identical: true,
            onlyInTree1: [],
            onlyInTree2: []
        };
    }

    const onlyInTree1 = findDifferingNodes(tree1, tree2);  //todo: This could be done in a single pass.
    const onlyInTree2 = findDifferingNodes(tree2, tree1);    
    return {
        identical: false,
        onlyInTree1,
        onlyInTree2
    };
}

