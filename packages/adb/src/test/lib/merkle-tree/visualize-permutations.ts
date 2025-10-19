import { createLeafNode, createParentNode, addFile, createTree, visualizeTree as libVisualizeTree, MerkleNode, FileHash, IMerkleTree } from '../../../lib/merkle-tree';
import { visualizeTreeSimple } from './merkle-verify';

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

function makePermutation(index: number, permutation: string[]) {
    console.log(`\n--- Permutation ${index + 1}: ${permutation.join(' → ')} ---`);

    let merkleTree: IMerkleTree<{}> = createTree('test-tree');

    // Add each file in the permutation order
    let stepIndex = 0;
    for (const fileName of permutation) {
        const fileHash = createTestFileHash(fileName);
        merkleTree = addFile(merkleTree, fileHash);

        console.log(`\n  Step ${stepIndex + 1}: Adding "${fileName}"`);
        const treeVisualization = visualizeTreeSimple(merkleTree.root);
        const indentedTree = treeVisualization.split('\n').map(line => '  ' + line).join('\n');
        console.log(indentedTree);
        stepIndex++;
    }

    console.log(`\n  Final tree for permutation ${index + 1}:`);
    const finalTreeVisualization = visualizeTreeSimple(merkleTree.root);
    const indentedFinalTree = finalTreeVisualization.split('\n').map(line => '  ' + line).join('\n');
    console.log(indentedFinalTree);
    console.log('─'.repeat(50));

    return merkleTree;
}

// Test function to visualize all permutations
function testAllPermutations() {
    const numFiles = 5;
    // Generate file names based on number of files
    const files = Array.from({ length: numFiles }, (_, i) => String.fromCharCode(97 + i)); // 'a', 'b', 'c', etc.
    const permutations = generatePermutations(files);
    
    console.log(`\n=== MERKLE TREE VISUALIZATION TEST ===`);
    console.log(`Testing all ${permutations.length} permutations of adding files: ${files.join(', ')}\n`);

    const firstPermutationTree = makePermutation(0, permutations[0]);
    const firstRootHash = firstPermutationTree.root?.hash.toString('hex');
    
    for (let index = 1; index < permutations.length; index++) {
        const permutation = permutations[index];
        const permutationTree = makePermutation(index, permutation);
        
        const currentRootHash = permutationTree.root?.hash.toString('hex');
        if (currentRootHash !== firstRootHash) {           
            console.error(`\n  ❌ HASH MISMATCH!`);
            console.error(`  Expected: ${firstRootHash}`);
            console.error(`  Got:      ${currentRootHash}`);
            console.error(`  Permutation: ${permutation.join(' → ')}`);

            console.log(`  First permutation:`);
            const firstTreeViz = visualizeTreeSimple(firstPermutationTree.root);
            const indentedFirstTreeViz = firstTreeViz.split('\n').map(line => '  ' + line).join('\n');
            console.log(indentedFirstTreeViz);

            throw new Error(`Hash mismatch for permutation ${index + 1}`);

        } else {
            console.log(`  ✅ Hash matches first permutation`);
        }
    }
    
    console.log(`\n=== SUMMARY ===`);
    console.log(`Tested ${permutations.length} different insertion orders`);
    console.log(`All permutations should result in the same final tree structure (balanced binary search tree)`);
}

// Run the test
testAllPermutations();
