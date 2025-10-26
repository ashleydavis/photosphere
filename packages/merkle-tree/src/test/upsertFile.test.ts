import * as crypto from 'crypto';
import { 
    FileHash, 
    upsertFile, 
    findFileNode,
    traverseTreeSync,
    createTree,
    MerkleNode,
    buildMerkleTree
} from '../lib/merkle-tree';

// Helper to create a file hash
function createFileHash(fileName: string, content: string): FileHash {
  const hash = crypto.createHash('sha256').update(content).digest();
  return {
    fileName,
    hash,
    length: content.length,
    lastModified: new Date(),
  };
}

describe('Merkle Tree upsertFile', () => {
  test('adds new file when the file does not exist', () => {
    // Create an empty tree
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    
    // Add a file
    const file1 = createFileHash('file1.txt', 'original content');
    tree = upsertFile(tree, file1);
    
    // Verify file was added
    expect(tree!.sort?.leafCount).toBe(1);
    
    // Add another file
    const file2 = createFileHash('file2.txt', 'second file');
    tree = upsertFile(tree, file2);
    
    // Verify both files exist
    expect(tree!.sort?.leafCount).toBe(2);
    
    const node1 = findFileNode(tree, 'file1.txt');
    const node2 = findFileNode(tree, 'file2.txt');
    
    expect(node1).toBeDefined();
    expect(node2).toBeDefined();
  });
  
  test('updates existing file', () => {
    // Create a tree with one file
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    const originalContent = 'original content';
    const file = createFileHash('file1.txt', originalContent);
    tree = upsertFile(tree, file);

    tree.dirty = false;
    tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
    
    // Verify initial state
    expect(tree!.sort?.leafCount).toBe(1);
    const originalNode = findFileNode(tree, 'file1.txt');
    expect(originalNode).toBeDefined();
    expect(originalNode!.contentHash!.toString('hex')).toBe(file.hash.toString('hex'));

    // Record original root hash
    const originalRootHash = tree!.merkle!.hash.toString('hex');
    
    // Now try to add a file with the same name but different content
    const updatedContent = 'updated content';
    const updatedFile = createFileHash('file1.txt', updatedContent);
    tree = upsertFile(tree, updatedFile);

    tree.dirty = false;
    tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
    
    // Verify the file was updated, not added
    expect(tree!.sort?.leafCount).toBe(1); // Still just one file
    
    // Verify the content was updated
    const updatedNode = findFileNode(tree, 'file1.txt');
    expect(updatedNode).toBeDefined();
    expect(updatedNode!.contentHash!.toString('hex')).toBe(updatedFile.hash.toString('hex'));
    
    // Verify the root hash changed (indicating the tree was updated)
    const newRootHash = tree!.merkle!.hash.toString('hex');
    expect(newRootHash).not.toBe(originalRootHash);
  });
  
  test('maintains tree structure when updating files', () => {
    // Create a tree with several files
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    
    // Add several files to create a multi-level tree
    const file1 = createFileHash('file1.txt', 'content 1');
    const file2 = createFileHash('file2.txt', 'content 2');
    const file3 = createFileHash('file3.txt', 'content 3');
    const file4 = createFileHash('file4.txt', 'content 4');
    
    tree = upsertFile(tree, file1);
    tree = upsertFile(tree, file2);
    tree = upsertFile(tree, file3);
    tree = upsertFile(tree, file4);
    
    // Verify initial state
    expect(tree!.sort?.leafCount).toBe(4);
    const initialNodeCount = tree!.sort?.nodeCount || 0;
        
    // Update an existing file
    const updatedFile2 = createFileHash('file2.txt', 'updated content 2');
    tree = upsertFile(tree, updatedFile2);
    
    // Verify structure is maintained
    expect(tree!.sort?.leafCount).toBe(4); // Still 4 files
    expect(tree!.sort?.nodeCount || 0).toBe(initialNodeCount); // Same node count
    
    // Verify all files are still present
    expect(findFileNode(tree, 'file1.txt')).toBeDefined();
    expect(findFileNode(tree, 'file2.txt')).toBeDefined();
    expect(findFileNode(tree, 'file3.txt')).toBeDefined();
    expect(findFileNode(tree, 'file4.txt')).toBeDefined();
    
    // Verify the correct file was updated
    const updatedNode = findFileNode(tree, 'file2.txt');
    expect(updatedNode!.contentHash!.toString('hex')).toBe(updatedFile2.hash.toString('hex'));   
  });
  
  test('propagates hash changes up the tree when updating', () => {
    // Create a small balanced tree
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    
    // Add files in a specific order
    const fileA = createFileHash('A.txt', 'content A');
    const fileB = createFileHash('B.txt', 'content B');
    const fileC = createFileHash('C.txt', 'content C');
    const fileD = createFileHash('D.txt', 'content D');
    
    tree = upsertFile(tree, fileA);
    tree = upsertFile(tree, fileB);
    tree = upsertFile(tree, fileC);
    tree = upsertFile(tree, fileD);

    tree.dirty = false;
    tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
    
    // Record original node hashes using depth-first traversal
    const originalHashes: string[] = [];
    traverseTreeSync<MerkleNode>(tree!.merkle, (node) => {
        originalHashes.push(node.hash.toString('hex'));
        return true; // Continue traversal
    });
    
    // Update one file
    const updatedFileC = createFileHash('C.txt', 'updated content C');
    tree = upsertFile(tree, updatedFileC);

    tree.dirty = false;
    tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
    
    // Verify the file node has the updated hash
    const nodeC = findFileNode(tree, 'C.txt');
    expect(nodeC!.contentHash!.toString('hex')).toBe(updatedFileC.hash.toString('hex'));
    
    // Verify that hashes have changed up the path to the root
    // In a balanced 4-file tree, the structure should be:
    //        Root(0)
    //       /      \
    //    AB(1)    CD(4)
    //   /  \      /  \
    //  A(2) B(3) C(5) D(6)
    
    // Collect new hashes using depth-first traversal
    const newHashes: string[] = [];
    traverseTreeSync<MerkleNode>(tree!.merkle, (node) => {
        newHashes.push(node.hash.toString('hex'));
        return true; // Continue traversal
    });
    
    // Expect changes in C node, CD node, and root node
    expect(newHashes[5]).not.toBe(originalHashes[5]); // C node hash changed
    expect(newHashes[4]).not.toBe(originalHashes[4]); // CD node hash changed
    expect(newHashes[0]).not.toBe(originalHashes[0]); // Root hash changed
    
    // But A and B branch should remain unchanged
    expect(newHashes[2]).toBe(originalHashes[2]); // A node hash unchanged
    expect(newHashes[3]).toBe(originalHashes[3]); // B node hash unchanged
    expect(newHashes[1]).toBe(originalHashes[1]); // AB node hash unchanged
    
    // D node hash should remain unchanged
    expect(newHashes[6]).toBe(originalHashes[6]); // D node hash unchanged
  });
  
  test('handle updates with identical content (no change needed)', () => {
    // Create a tree with one file
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    const content = 'original content';
    const file = createFileHash('file1.txt', content);
    tree = upsertFile(tree, file);

    tree.dirty = false;
    tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
    
    // Record the original root hash
    const originalRootHash = tree!.merkle!.hash.toString('hex');
    
    // Try to update with identical content
    const sameFile = createFileHash('file1.txt', content);
    tree = upsertFile(tree, sameFile);

    tree.dirty = false;
    tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
    
    // Since the content is identical, the tree should be unchanged
    // Verify the root hash hasn't changed
    const newRootHash = tree!.merkle!.hash.toString('hex');
    expect(newRootHash).toBe(originalRootHash);
  });
  
  test('handles multiple add/update operations on files', () => {
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    
    // Initial addition of files
    tree = upsertFile(tree, createFileHash('file1.txt', 'content 1'));
    tree = upsertFile(tree, createFileHash('file2.txt', 'content 2'));
    
    // Verify initial state
    expect(tree!.sort?.leafCount).toBe(2);
    
    // Update first file
    tree = upsertFile(tree, createFileHash('file1.txt', 'updated content 1'));
    
    // Add a new file
    tree = upsertFile(tree, createFileHash('file3.txt', 'content 3'));
    
    // Update second file
    tree = upsertFile(tree, createFileHash('file2.txt', 'updated content 2'));
    
    // Update third file
    tree = upsertFile(tree, createFileHash('file3.txt', 'updated content 3'));
    
    // Verify final state
    expect(tree!.sort?.leafCount).toBe(3);
    
    // Verify all files have the updated content
    const node1 = findFileNode(tree, 'file1.txt');
    const node2 = findFileNode(tree, 'file2.txt');
    const node3 = findFileNode(tree, 'file3.txt');
    
    expect(node1!.contentHash!.toString('hex')).toBe(
      crypto.createHash('sha256').update('updated content 1').digest().toString('hex')
    );
    
    expect(node2!.contentHash!.toString('hex')).toBe(
      crypto.createHash('sha256').update('updated content 2').digest().toString('hex')
    );
    
    expect(node3!.contentHash!.toString('hex')).toBe(
      crypto.createHash('sha256').update('updated content 3').digest().toString('hex')
    );
  });
});