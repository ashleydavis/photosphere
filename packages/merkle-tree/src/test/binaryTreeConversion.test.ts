import { describe, it, expect } from "@jest/globals";
import { createTree, addFile, binaryTreeToArray, arrayToBinaryTree, traverseTreeSync, FileHash } from "../lib/merkle-tree";

describe('Binary Tree Conversion Functions', () => {

    /**
     * Helper function to create a file hash with a given name and content
     */
    function createFileHash(fileName: string, content?: Buffer, lastModified?: Date, size?: number): FileHash {
        return {
            fileName,
            hash: Buffer.from(fileName + (content || "default content")),
            lastModified: lastModified || new Date('2023-01-01'),
            length: size || (content?.length || fileName.length),
        };
    }
    
    describe('binaryTreeToArray', () => {
        
        it('should handle empty tree', () => {
            const result = binaryTreeToArray(undefined);
            expect(result).toEqual([]);
        });

        it('should convert single node tree correctly', () => {
            const tree = createTree("test-tree");
            const fileHash = createFileHash("test1.txt", Buffer.from("content1"), new Date(), 8);
            const updatedTree = addFile(tree, fileHash);
            
            const flatArray = binaryTreeToArray(updatedTree.sort);
            
            expect(flatArray).toHaveLength(1);
            expect(flatArray[0].fileName).toBe("test1.txt");
            expect(flatArray[0].nodeCount).toBe(1);
            expect(flatArray[0].leafCount).toBe(1);
            expect(flatArray[0]).not.toHaveProperty('left');
            expect(flatArray[0]).not.toHaveProperty('right');
        });

        it('should convert small tree with multiple nodes', () => {
            let tree = createTree("test-tree");
            
            // Add 3 files to create a small tree
            const files = [
                createFileHash("file1.txt", Buffer.from("content1"), new Date(), 8),
                createFileHash("file2.txt", Buffer.from("content2"), new Date(), 8),
                createFileHash("file3.txt", Buffer.from("content3"), new Date(), 8)
            ];
            
            for (const file of files) {
                tree = addFile(tree, file);
            }
            
            const flatArray = binaryTreeToArray(tree.sort);
            
            // Should have 5 nodes (3 leaves + 2 internal nodes)
            expect(flatArray).toHaveLength(5);
            
            // Check that no node has left/right properties in flat array
            for (const node of flatArray) {
                expect(node).not.toHaveProperty('left');
                expect(node).not.toHaveProperty('right');
            }
            
            // Root node should be first and have nodeCount of 5
            expect(flatArray[0].nodeCount).toBe(5);
            expect(flatArray[0].leafCount).toBe(3);
        });

        it('should preserve all node properties except left/right', () => {
            let tree = createTree("test-tree");
            const fileHash = createFileHash("test.txt", Buffer.from("content"), new Date(), 8);
            tree = addFile(tree, fileHash);
            
            const flatArray = binaryTreeToArray(tree.sort);
            const node = flatArray[0];
            
            expect(node).toHaveProperty('contentHash');
            expect(node).toHaveProperty('fileName', 'test.txt');
            expect(node).toHaveProperty('nodeCount', 1);
            expect(node).toHaveProperty('leafCount', 1);
            expect(node).toHaveProperty('size');
            expect(node).toHaveProperty('lastModified');
            expect(node).not.toHaveProperty('left');
            expect(node).not.toHaveProperty('right');
        });

    });

    describe('arrayToBinaryTree', () => {
        
        it('should handle empty array', () => {
            const result = arrayToBinaryTree([]);
            expect(result).toBeUndefined();
        });

        it('should convert single node array correctly', () => {
            const tree = createTree("test-tree");
            const fileHash = createFileHash("test1.txt", Buffer.from("content1"), new Date(), 8);
            const updatedTree = addFile(tree, fileHash);
            
            // Convert to array and back
            const flatArray = binaryTreeToArray(updatedTree.sort);
            const reconstructed = arrayToBinaryTree(flatArray);
            
            expect(reconstructed).toBeDefined();
            expect(reconstructed!.fileName).toBe("test1.txt");
            expect(reconstructed!.nodeCount).toBe(1);
            expect(reconstructed!.leafCount).toBe(1);
            expect(reconstructed!.left).toBeUndefined();
            expect(reconstructed!.right).toBeUndefined();
        });

        it('should reconstruct tree structure correctly for multiple nodes', () => {
            let tree = createTree("test-tree");
            
            // Add files to create a tree structure
            const files = [
                createFileHash("file1.txt", Buffer.from("content1"), new Date(), 8),
                createFileHash("file2.txt", Buffer.from("content2"), new Date(), 8),
                createFileHash("file3.txt", Buffer.from("content3"), new Date(), 8)
            ];
            
            for (const file of files) {
                tree = addFile(tree, file);
            }
            
            // Convert to array and back
            const flatArray = binaryTreeToArray(tree.sort);
            const reconstructed = arrayToBinaryTree(flatArray);
            
            expect(reconstructed).toBeDefined();
            expect(reconstructed!.nodeCount).toBe(5);
            expect(reconstructed!.leafCount).toBe(3);
            
            // Check that internal nodes have children
            if (reconstructed!.nodeCount > 1) {
                expect(reconstructed!.left || reconstructed!.right).toBeDefined();
            }
        });

        it('should preserve all node properties', () => {
            let tree = createTree("test-tree");
            const fileHash = createFileHash("test.txt", Buffer.from("content"), new Date(), 8);
            tree = addFile(tree, fileHash);
            
            // Convert to array and back
            const flatArray = binaryTreeToArray(tree.sort);
            const reconstructed = arrayToBinaryTree(flatArray);
            
            expect(reconstructed).toBeDefined();
            //TODO: Should this test be on the merkle tree instead of the sort tree?
            // expect(reconstructed!.hash).toEqual(tree.sort!.hash);
            expect(reconstructed!.fileName).toBe(tree.sort!.fileName);
            expect(reconstructed!.nodeCount).toBe(tree.sort!.nodeCount);
            expect(reconstructed!.leafCount).toBe(tree.sort!.leafCount);
            expect(reconstructed!.size).toBe(tree.sort!.size);
            expect(reconstructed!.lastModified).toEqual(tree.sort!.lastModified);
        });

    });

    describe('Round-trip conversion', () => {
        
        it('should maintain tree integrity through conversion cycle', () => {
            let tree = createTree("test-tree");
            
            // Create a larger tree for comprehensive testing
            const files = [];
            for (let i = 1; i <= 7; i++) {
                files.push(createFileHash(`file${i}.txt`, Buffer.from(`content${i}`), new Date(), 8));
            }
            
            for (const file of files) {
                tree = addFile(tree, file);
            }
            
            const originalRoot = tree.sort;
            
            // Round-trip: binary tree -> array -> binary tree
            const flatArray = binaryTreeToArray(originalRoot);
            const reconstructed = arrayToBinaryTree(flatArray);
            
            expect(reconstructed).toBeDefined();
            expect(reconstructed!.nodeCount).toBe(originalRoot!.nodeCount);
            expect(reconstructed!.leafCount).toBe(originalRoot!.leafCount);
            expect(reconstructed!.size).toBe(originalRoot!.size);
            //TODO: Should this test be on the merkle tree instead of the sort tree?
            // expect(reconstructed!.hash).toEqual(originalRoot!.hash);
        });

        it('should handle leaf nodes correctly in round-trip', () => {
            let tree = createTree("test-tree");
            const fileHash = createFileHash("single.txt", Buffer.from("content"), new Date(), 8);
            tree = addFile(tree, fileHash);
            
            // Round-trip conversion
            const flatArray = binaryTreeToArray(tree.sort);
            const reconstructed = arrayToBinaryTree(flatArray);
            
            // Should be identical for leaf nodes
            expect(reconstructed).toBeDefined();
            expect(reconstructed!.fileName).toBe("single.txt");
            expect(reconstructed!.nodeCount).toBe(1);
            expect(reconstructed!.left).toBeUndefined();
            expect(reconstructed!.right).toBeUndefined();
        });

        it('should maintain correct tree structure after round-trip', () => {
            let tree = createTree("test-tree");
            
            // Add enough files to create a multi-level tree
            for (let i = 1; i <= 4; i++) {
                const fileHash = createFileHash(`file${i}.txt`, Buffer.from(`content${i}`), new Date(), 8);
                tree = addFile(tree, fileHash);
            }
            
            // Convert to flat array and back
            const flatArray = binaryTreeToArray(tree.sort);
            const reconstructed = arrayToBinaryTree(flatArray);
            
            // Verify tree structure is maintained
            function verifyTreeStructure(node: any): void {
                if (!node) return;
                
                if (node.nodeCount === 1) {
                    // Leaf node - should have no children and fileName
                    expect(node.left).toBeUndefined();
                    expect(node.right).toBeUndefined();
                    expect(node.fileName).toBeDefined();
                } else {
                    // Internal node - should have children, no fileName
                    expect(node.fileName).toBeUndefined();
                    
                    // Verify that node count matches actual structure
                    let expectedCount = 1; // Count this node
                    if (node.left) {
                        expectedCount += node.left.nodeCount;
                        verifyTreeStructure(node.left);
                    }
                    if (node.right) {
                        expectedCount += node.right.nodeCount;
                        verifyTreeStructure(node.right);
                    }
                    
                    expect(node.nodeCount).toBe(expectedCount);
                }
            }
            
            expect(reconstructed).toBeDefined();
            verifyTreeStructure(reconstructed);
        });

    });

});
