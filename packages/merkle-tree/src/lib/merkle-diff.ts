import { BufferSet } from './buffer-set';
import { MerkleNode } from './merkle-tree';

export interface MerkleTreeDiff {
    identical: boolean;
    onlyInTree1: MerkleNode[];
    onlyInTree2: MerkleNode[];
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
export function findDifferingNodes(
    treeA: MerkleNode,
    treeB: MerkleNode
): MerkleNode[] {
    
    // Set of hashes from tree B (lazily populated)
    const setB = new BufferSet();
    
    // Queue for traversing tree A breadth-first
    let queueA: MerkleNode[] = [treeA];
    
    // Queue for expanding tree B level by level
    let queueB: MerkleNode[] = [treeB];
    
    while (queueA.length > 0 && queueB.length > 0) {
        // Expand the next level of tree B into the set.
        if (queueB.length > 0) {
            const currentLevelB = queueB;
            queueB = [];

            for (const nodeB of currentLevelB) {
                // Hashes from tree B are in the set when they are no longer in the queue.
                setB.add(nodeB.hash); 

                if (nodeB.left && nodeB.right) {
                    // Queue children of nodeB to further expand the set on the next iteration.
                    queueB.push(nodeB.left);
                    queueB.push(nodeB.right);
                } else if (nodeB.left) {
                    throw new Error('Invalid tree structure: nodeB has a left child but no right child');
                } else if (nodeB.right) {
                    throw new Error('Invalid tree structure: nodeB has a right child but no left child');
                } else {
                    // nodeB is a leaf node, at this point we have worked our way through tree B.
                }
            }
        }

        const currentLevelA = queueA; // Process the current level of tree A.
        queueA = []; // Clear the queue for the next level.

        for (const nodeA of currentLevelA) {
            // Check if this node exists in tree B
            if (setB.has(nodeA.hash)) {
                setB.delete(nodeA.hash);
                // Don't add children of nodeA to queue - subtree is identical
                continue;
            }
                    
            if (nodeA.left && nodeA.right) {
                // Queue children of nodeA to check against expanded setB in next iteration.
                queueA.push(nodeA.left);
                queueA.push(nodeA.right);
            } else if (nodeA.left) {
                throw new Error('Invalid tree structure: nodeA has a left child but no right child');
            } else if (nodeA.right) {
                throw new Error('Invalid tree structure: nodeA has a right child but no left child');
            } else {
                // This is a leaf node, requeue it to check against the expanded setB in next iteration.
                queueA.push(nodeA);
            }
        }
    }

    const onlyInTree1: MerkleNode[] = [];

    //
    // We need to one more round of checking queue a hashes against set b.
    // For hashes in queue a that match set b, remove them from queue a.
    //
    if (queueA.length > 0) {
        for (const nodeA of queueA) {
            if (!setB.has(nodeA.hash)) {
                onlyInTree1.push(nodeA);
            }
        }
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

