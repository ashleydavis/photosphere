import { createLeafNode, createParentNode, addFile, createTree, visualizeTree as libVisualizeTree, MerkleNode, FileHash, IMerkleTree } from '../../../lib/merkle-tree';
import { visualizeTree } from './merkle-verify';

// Helper function to create a FileHash for testing
function createTestFileHash(fileName: string): FileHash {
    return {
        fileName,
        hash: Buffer.from(fileName, 'utf8'), // Simple hash for testing
        length: fileName.length,
        lastModified: new Date()
    };
}

// Helper function to generate all permutations of an array
function generatePermutations<T>(arr: T[]): T[][] {
    if (arr.length <= 1) return [arr];
    
    const result: T[][] = [];
    for (let i = 0; i < arr.length; i++) {
        const current = arr[i];
        const remaining = [...arr.slice(0, i), ...arr.slice(i + 1)];
        const permutations = generatePermutations(remaining);
        for (const perm of permutations) {
            result.push([current, ...perm]);
        }
    }
    return result;
}

// Helper function to get tree statistics
function getTreeStats(node: MerkleNode | undefined): { height: number, nodeCount: number, leafCount: number } {
    if (!node) return { height: 0, nodeCount: 0, leafCount: 0 };
    
    const leftStats = getTreeStats(node.left);
    const rightStats = getTreeStats(node.right);
    
    return {
        height: 1 + Math.max(leftStats.height, rightStats.height),
        nodeCount: node.nodeCount,
        leafCount: node.leafCount
    };
}

// Test function to visualize all permutations
function testAllPermutations() {
    const files = ['a', 'b', 'c', 'd', 'e'];
    const permutations = generatePermutations(files);
    
    console.log(`\n=== MERKLE TREE VISUALIZATION TEST ===`);
    console.log(`Testing all ${permutations.length} permutations of adding files: ${files.join(', ')}\n`);
    
    permutations.forEach((permutation, index) => {
        console.log(`\n--- Permutation ${index + 1}: ${permutation.join(' → ')} ---`);
        
        let merkleTree: IMerkleTree<{}> = createTree('test-tree');
        
        // Add each file in the permutation order
        let stepIndex = 0;
        for (const fileName of permutation) {
            const fileHash = createTestFileHash(fileName);
            merkleTree = addFile(merkleTree, fileHash);
            
            console.log(`\n  Step ${stepIndex + 1}: Adding "${fileName}"`);
            const treeVisualization = visualizeTree(merkleTree.root);
            const indentedTree = treeVisualization.split('\n').map(line => '  ' + line).join('\n');
            console.log(indentedTree);
            stepIndex++;
        }
        
        console.log(`\n  Final tree for permutation ${index + 1}:`);
        const finalTreeVisualization = visualizeTree(merkleTree.root);
        const indentedFinalTree = finalTreeVisualization.split('\n').map(line => '  ' + line).join('\n');
        console.log(indentedFinalTree);
        console.log('─'.repeat(50));
    });
    
    console.log(`\n=== SUMMARY ===`);
    console.log(`Tested ${permutations.length} different insertion orders`);
    console.log(`All permutations should result in the same final tree structure (balanced binary search tree)`);
}

// Run the test
testAllPermutations();
