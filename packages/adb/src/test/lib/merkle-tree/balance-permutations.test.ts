import { addFile, createTree, FileHash, IMerkleTree, SortNode, rebalanceTree } from '../../../lib/merkle-tree';
import { buildTree, createFileHash } from './merkle-verify';

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

// Helper function to check if a tree is balanced
function isTreeBalanced(node: SortNode | undefined): boolean {
    if (!node) return true;
    
    // Leaf nodes are always balanced
    if (node.nodeCount === 1) return true;
    
    // Check if this node is balanced (difference between left and right node counts <= 2)
    const leftCount = node.left?.nodeCount || 0;
    const rightCount = node.right?.nodeCount || 0;
    const balance = Math.abs(leftCount - rightCount);
    
    if (balance > 2) {
        return false;
    }
    
    // Recursively check both subtrees
    return isTreeBalanced(node.left) && isTreeBalanced(node.right);
}

// Helper function to get detailed balance information for debugging
function getBalanceInfo(node: SortNode | undefined, depth: number = 0): string {
    if (!node) return '';
    
    const indent = '  '.repeat(depth);
    let info = `${indent}Node: ${node.fileName || 'internal'} (nodeCount: ${node.nodeCount})\n`;
    
    if (node.left || node.right) {
        const leftCount = node.left?.nodeCount || 0;
        const rightCount = node.right?.nodeCount || 0;
        const balance = leftCount - rightCount;
        info += `${indent}  Balance: ${balance} (left: ${leftCount}, right: ${rightCount})\n`;
        
        if (node.left) {
            info += getBalanceInfo(node.left, depth + 1);
        }
        if (node.right) {
            info += getBalanceInfo(node.right, depth + 1);
        }
    }
    
    return info;
}

describe('Merkle Tree Balance Verification for Permutations', () => {
    // Test all permutations of 3 files (6 permutations)
    const threeFilePermutations = generatePermutations(['a', 'b', 'c']);
    for (let i = 0; i < threeFilePermutations.length; i++) {
        const permutation = threeFilePermutations[i];
        test(`3 files permutation ${i + 1}: ${permutation.join(' → ')} should result in balanced tree`, () => {
            const merkleTree = buildTree(permutation);
            const isBalanced = isTreeBalanced(merkleTree.sortRoot);
            
            if (!isBalanced) {
                const balanceInfo = getBalanceInfo(merkleTree.sortRoot);
                console.log(`\n=== UNBALANCED TREE DETAILS ===`);
                console.log(`Permutation: ${permutation.join(' → ')}`);
                console.log(`Balance info:`);
                console.log(balanceInfo);
            }
            
            expect(isBalanced).toBe(true);
        });
    }

    // Test all permutations of 4 files (24 permutations)
    const fourFilePermutations = generatePermutations(['a', 'b', 'c', 'd']);
    for (let i = 0; i < fourFilePermutations.length; i++) {
        const permutation = fourFilePermutations[i];
        test(`4 files permutation ${i + 1}: ${permutation.join(' → ')} should result in balanced tree`, () => {
            const merkleTree = buildTree(permutation);
            const isBalanced = isTreeBalanced(merkleTree.sortRoot);
            
            if (!isBalanced) {
                const balanceInfo = getBalanceInfo(merkleTree.sortRoot);
                console.log(`\n=== UNBALANCED TREE DETAILS ===`);
                console.log(`Permutation: ${permutation.join(' → ')}`);
                console.log(`Balance info:`);
                console.log(balanceInfo);
            }
            
            expect(isBalanced).toBe(true);
        });
    }

    // Test all permutations of 5 files (120 permutations)
    const fiveFilePermutations = generatePermutations(['a', 'b', 'c', 'd', 'e']);
    for (let i = 0; i < fiveFilePermutations.length; i++) {
        const permutation = fiveFilePermutations[i];
        test(`5 files permutation ${i + 1}: ${permutation.join(' → ')} should result in balanced tree`, () => {
            const merkleTree = buildTree(permutation);
            const isBalanced = isTreeBalanced(merkleTree.sortRoot);
            
            if (!isBalanced) {
                const balanceInfo = getBalanceInfo(merkleTree.sortRoot);
                console.log(`\n=== UNBALANCED TREE DETAILS ===`);
                console.log(`Permutation: ${permutation.join(' → ')}`);
                console.log(`Balance info:`);
                console.log(balanceInfo);
            }
            
            expect(isBalanced).toBe(true);
        });
    }

    // Test that balance criteria matches rebalanceTree function for a sample of permutations
    test('verify balance criteria matches rebalanceTree function', () => {
        // Test that our balance checking logic matches the rebalanceTree function's criteria
        const files = ['a', 'b', 'c', 'd', 'e'];
        const permutations = generatePermutations(files);
        
        let treesNeedingRebalancing = 0;
        
        for (const permutation of permutations) {
            const merkleTree = buildTree(permutation);
            
            if (merkleTree.sortRoot) {
                // Check if our balance function thinks it needs rebalancing
                const isBalanced = isTreeBalanced(merkleTree.sortRoot);
                
                // Check if rebalanceTree would change the tree
                const rebalanced = rebalanceTree(merkleTree.sortRoot);
                const needsRebalancing = rebalanced !== merkleTree.sortRoot;
                
                if (needsRebalancing) {
                    treesNeedingRebalancing++;
                }
                
                // Our balance check should match the rebalanceTree behavior
                expect(isBalanced).toBe(!needsRebalancing);
            }
        }
        
        // console.log(`\n=== BALANCE CRITERIA VERIFICATION ===`);
        // console.log(`Trees that need rebalancing: ${treesNeedingRebalancing}/${permutations.length}`);
        // console.log(`Our balance check should match rebalanceTree behavior`);
    });
});
