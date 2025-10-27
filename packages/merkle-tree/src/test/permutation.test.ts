import { createTree, addItem, IMerkleTree, buildMerkleTree } from '../lib/merkle-tree';
import { visualizeMerkleTree } from '../lib/visualize';
import { createHashedItem } from './merkle-verify';

describe('Merkle Tree Permutation Tests', () => {
  const testFiles = ['a', 'b', 'c', 'd', 'e'];
  
  // Generate all permutations of the test files
  function generatePermutations<T>(arr: T[]): T[][] {
    if (arr.length <= 1) return [arr];
    
    const permutations: T[][] = [];
    for (let i = 0; i < arr.length; i++) {
      const current = arr[i];
      const remaining = [...arr.slice(0, i), ...arr.slice(i + 1)];
      const remainingPermutations = generatePermutations(remaining);
      
      for (const perm of remainingPermutations) {
        permutations.push([current, ...perm]);
      }
    }
    
    return permutations;
  }

  function createPermutationTree(permutation: string[]): IMerkleTree<any> {
    let tree = createTree<any>("12345678-1234-5678-9abc-123456789abc");
  
    // Add files in the permutation order
    for (const file of permutation) {
      const fileHash = createHashedItem(file);
      tree = addItem(tree, fileHash);

      // console.log(`Added file ${file} to tree:`);
      // console.log(`Tree:\n${visualizeTree(tree.root)}`);
    }
    return tree;
  }

  const permutations = generatePermutations(testFiles);
  const comparisonPermutation = permutations[0];

  // console.log(`Creating tree 1 [${comparisonPermutation.join('-')}]`);
  const comparisonTree = createPermutationTree(comparisonPermutation);

  comparisonTree.dirty = false;
  comparisonTree.merkle = buildMerkleTree(comparisonTree.sort); // Force tree rebuild.
  
  // Test that every other permutation produces the same tree as the first permutation.
  for (let index = 1; index < permutations.length; index++) {
    const permutation = permutations[index];
  
    test(`should produce same tree for permutation 1 [${comparisonPermutation.join('-')}] and ${index + 1} [${permutation.join('-')}]`, () => {
      // console.log(`Creating tree ${index + 1} [${permutation.join('-')}]`);
      const permutationTree = createPermutationTree(permutation);

      permutationTree.dirty = false;
      permutationTree.merkle = buildMerkleTree(permutationTree.sort); // Force tree rebuild.

      const root = permutationTree.merkle;
      expect(root).toBeDefined();

      const same = Buffer.compare(root!.hash, comparisonTree.merkle!.hash) === 0;
      if (!same) {
        const msg = `Permutation ${index + 1} [${permutation.join(', ')}] produces a different tree to permutation 1 [${comparisonPermutation.join(', ')}].`;
        console.log(msg);
        console.log(`Comparison:  ${comparisonTree.merkle!.hash.toString('hex')}`);
        console.log(`Permutation: ${root!.hash.toString('hex')}`);
        console.log(`Comparison:\n${visualizeMerkleTree(comparisonTree.merkle)}`);
        console.log(`Permutation:\n${visualizeMerkleTree(root)}`);

        throw new Error(msg);
      }
    });
  }
});

