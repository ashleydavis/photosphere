import * as crypto from 'crypto';
import { findParentIndex, MerkleNode } from '../../../lib/merkle-tree';

describe('findParentIndex function tests', () => {

    // Helper function to create a leaf node
    function createLeafNode(hash: Buffer, fileName: string): MerkleNode {
        return {
            hash,
            fileName,
            nodeCount: 1,
            leafCount: 1,
            size: 1,
        };
    }

    // Helper function to create a parent node
    function createParentNode(hash: Buffer, leftNode: MerkleNode, rightNode: MerkleNode): MerkleNode {
        return {
            hash,
            fileName: undefined,
            nodeCount: 1 + leftNode.nodeCount + rightNode.nodeCount,
            leafCount: leftNode.leafCount + rightNode.leafCount,
            size: leftNode.size + rightNode.size,
        };
    }

    // Helper function to create a hash
    function createHash(content: string): Buffer {
        return crypto.createHash('sha256').update(content).digest();
    }

    test('shallow balanced tree', () => {
        /*
             Root(0)
            /     \
           A(1)   B(2)
        */
        const leafA = createLeafNode(createHash('A'), 'A');
        const leafB = createLeafNode(createHash('B'), 'B');
        const root = createParentNode(createHash('Root'), leafA, leafB);

        const nodes = [root, leafA, leafB];

        // Test left child
        expect(findParentIndex(1, nodes)).toBe(0); // A's parent should be root

        // Test right child
        expect(findParentIndex(2, nodes)).toBe(0); // B's parent should be root

        // Test root (should have no parent)
        expect(findParentIndex(0, nodes)).toBe(-1);
    });

    test('deeper balanced tree', () => {
        /*
              Root(0)
             /       \
            A(1)      B(4)
           /   \     /   \
          C(2) D(3) E(5) F(6)
        */
        const leafC = createLeafNode(createHash('C'), 'C');
        const leafD = createLeafNode(createHash('D'), 'D');
        const leafE = createLeafNode(createHash('E'), 'E');
        const leafF = createLeafNode(createHash('F'), 'F');

        const nodeA = createParentNode(createHash('A'), leafC, leafD);
        const nodeB = createParentNode(createHash('B'), leafE, leafF);

        const root = createParentNode(createHash('Root'), nodeA, nodeB);

        const nodes = [root, nodeA, leafC, leafD, nodeB, leafE, leafF];

        // Test the key case: nodeB's parent
        // This is a right child where the node before it isn't its parent
        expect(findParentIndex(4, nodes)).toBe(0); // B's parent should be Root, not nodeA

        // Test other relationships too
        expect(findParentIndex(1, nodes)).toBe(0); // A's parent is Root
        expect(findParentIndex(2, nodes)).toBe(1); // C's parent is A
        expect(findParentIndex(3, nodes)).toBe(1); // D's parent is A
        expect(findParentIndex(5, nodes)).toBe(4); // E's parent is B
        expect(findParentIndex(6, nodes)).toBe(4); // F's parent is B
    });

    test('even deeper balanced tree', () => {
        /*
                              Root(0)
                      /                     \
                    A(1)                    B(8)
                   /     \              /         \
                 C(2)      D(5)       E(9)        F(12)
                /   \     /   \      /    \      /    \
               G(3) H(4) I(6) J(7) K(10) L(11)  M(13) N(14)
        */

        // Create leaf nodes
        const leafG = createLeafNode(createHash('G'), 'G');
        const leafH = createLeafNode(createHash('H'), 'H');
        const leafI = createLeafNode(createHash('I'), 'I');
        const leafJ = createLeafNode(createHash('J'), 'J');
        const leafK = createLeafNode(createHash('K'), 'K');
        const leafL = createLeafNode(createHash('L'), 'L');
        const leafM = createLeafNode(createHash('M'), 'M');
        const leafN = createLeafNode(createHash('N'), 'N');

        // Create level 2 nodes
        const nodeC = createParentNode(createHash('C'), leafG, leafH);
        const nodeD = createParentNode(createHash('D'), leafI, leafJ);
        const nodeE = createParentNode(createHash('E'), leafK, leafL);
        const nodeF = createParentNode(createHash('F'), leafM, leafN);

        // Create level 1 nodes
        const nodeA = createParentNode(createHash('A'), nodeC, nodeD);
        const nodeB = createParentNode(createHash('B'), nodeE, nodeF);

        // Create root
        const root = createParentNode(createHash('Root'), nodeA, nodeB);

        // Flattened tree in depth-first order
        const nodes = [
            root, // 0
            nodeA, nodeC, leafG, leafH, nodeD, leafI, leafJ,  // 1-7
            nodeB, nodeE, leafK, leafL, nodeF, leafM, leafN   // 8-14
        ];

        // Test each node's parent
        expect(findParentIndex(1, nodes)).toBe(0);  // A's parent is Root
        expect(findParentIndex(8, nodes)).toBe(0);  // B's parent is Root

        expect(findParentIndex(2, nodes)).toBe(1);  // C's parent is A
        expect(findParentIndex(5, nodes)).toBe(1);  // D's parent is A
        expect(findParentIndex(9, nodes)).toBe(8);  // E's parent is B
        expect(findParentIndex(12, nodes)).toBe(8); // F's parent is B

        expect(findParentIndex(3, nodes)).toBe(2);  // G's parent is C
        expect(findParentIndex(4, nodes)).toBe(2);  // H's parent is C
        expect(findParentIndex(6, nodes)).toBe(5);  // I's parent is D
        expect(findParentIndex(7, nodes)).toBe(5);  // J's parent is D
        expect(findParentIndex(10, nodes)).toBe(9); // K's parent is E
        expect(findParentIndex(11, nodes)).toBe(9); // L's parent is E
        expect(findParentIndex(13, nodes)).toBe(12); // M's parent is F
        expect(findParentIndex(14, nodes)).toBe(12); // N's parent is F
    });

    test('left heavy tree', () => {
        /*
               Root(0)
              /      \
             A(1)     D(4)
            /  \     
           B    C    
           2    3    
        */

        const leafB = createLeafNode(createHash('B'), 'B');
        const leafC = createLeafNode(createHash('C'), 'C');
        const leafD = createLeafNode(createHash('D'), 'D');
        const nodeA = createParentNode(createHash('A'), leafB, leafC);
        const root = createParentNode(createHash('Root'), nodeA, leafD);
        
        const nodes = [root, nodeA, leafB, leafC, leafD];

        expect(findParentIndex(1, nodes)).toBe(0);  // A's parent is Root
        expect(findParentIndex(2, nodes)).toBe(1);  // B's parent is A
        expect(findParentIndex(3, nodes)).toBe(1);  // C's parent is A
        expect(findParentIndex(4, nodes)).toBe(0);  // D's parent is Root
    });

    test('right heavy sub tree in a left heavy tree', () => {
        /*
               Root(0)
              /      \
             A(1)     B(6)
            /  \     
           C    D(3)   
           2     / \
                E   F
                4   5    
               
        */

        const leafC = createLeafNode(createHash('C'), 'C');
        const leafE = createLeafNode(createHash('E'), 'E');
        const leafF = createLeafNode(createHash('F'), 'F');
        const nodeD = createParentNode(createHash('D'), leafE, leafF);
        const nodeA = createParentNode(createHash('A'), leafC, nodeD);
        const leafB = createLeafNode(createHash('B'), 'B');
        const root = createParentNode(createHash('Root'), nodeA, leafB);

        const nodes = [root, nodeA, leafC, nodeD, leafE, leafF, leafB];

        expect(findParentIndex(1, nodes)).toBe(0);  // A's parent is Root
        expect(findParentIndex(6, nodes)).toBe(0);  // B's parent is Root
        expect(findParentIndex(2, nodes)).toBe(1);  // C's parent is A
        expect(findParentIndex(3, nodes)).toBe(1);  // D's parent is A
        expect(findParentIndex(4, nodes)).toBe(3);  // E's parent is D
        expect(findParentIndex(5, nodes)).toBe(3);  // F's parent is D
    });

    test('right heavy tree', () => {
        /*
               Root(0)
              /      \
             A(1)     B(2)
                      /  \
                     D    E
                     3    4
        */

        const leafA = createLeafNode(createHash('A'), 'A');
        const leafD = createLeafNode(createHash('D'), 'D');
        const leafE = createLeafNode(createHash('E'), 'E');
        const nodeB = createParentNode(createHash('B'), leafD, leafE);
        const root = createParentNode(createHash('Root'), leafA, nodeB);

        const nodes = [root, leafA, nodeB, leafD, leafE];

        expect(findParentIndex(1, nodes)).toBe(0);  // A's parent is Root
        expect(findParentIndex(2, nodes)).toBe(0);  // B's parent is Root
        expect(findParentIndex(3, nodes)).toBe(2);  // D's parent is B
        expect(findParentIndex(4, nodes)).toBe(2);  // E's parent is B                     
    });

    test('left heavy subtree in a right heavy tree', () => {
        /*
               Root(0)
              /      \
             A(1)     B(2)
                      /   \
                     D(3)  E
                     /  \  6
                    G    H 
                    4    5
        */

        const leafA = createLeafNode(createHash('A'), 'A');
        const leafG = createLeafNode(createHash('G'), 'G');
        const leafH = createLeafNode(createHash('H'), 'H');
        const nodeD = createParentNode(createHash('D'), leafG, leafH);
        const leafE = createLeafNode(createHash('E'), 'E');
        const nodeB = createParentNode(createHash('B'), nodeD, leafE);
        const root = createParentNode(createHash('Root'), leafA, nodeB);

        const nodes = [root, leafA, nodeB, nodeD, leafG, leafH, leafE];

        expect(findParentIndex(1, nodes)).toBe(0);  // A's parent is Root
        expect(findParentIndex(2, nodes)).toBe(0);  // B's parent is Root
        expect(findParentIndex(3, nodes)).toBe(2);  // D's parent is B
        expect(findParentIndex(4, nodes)).toBe(3);  // G's parent is D
        expect(findParentIndex(5, nodes)).toBe(3);  // H's parent is D
        expect(findParentIndex(6, nodes)).toBe(2);  // E's parent is B
    });

    test('bigger tree', () => {
        /*
             Root(0)
            /     \
           A(1)    D(6)
          / \     / \
         B   C   E   F
         2   3   7   8
            / \     / \
           G   H   I   J
           4   5   9   10
        
        */
        
        // Create leaf nodes
        const leafB = createLeafNode(createHash('B'), 'B');
        const leafG = createLeafNode(createHash('G'), 'G');
        const leafH = createLeafNode(createHash('H'), 'H');
        const leafE = createLeafNode(createHash('E'), 'E');
        const leafJ = createLeafNode(createHash('J'), 'J');
        
        // Create node C with children G, H
        const nodeC = createParentNode(createHash('C'), leafG, leafH);
        
        // Create node I with only right child K
        const nodeI = createLeafNode(createHash('I'), 'I');
       
        // Create node F with only left child I and right child J
        const nodeF = createParentNode(createHash('F'), nodeI, leafJ);
        
        // Create node A with children B, C
        const nodeA = createParentNode(createHash('A'), leafB, nodeC);
        
        // Create node D with children E, F
        const nodeD = createParentNode(createHash('D'), leafE, nodeF);
        
        // Create root with children A, D
        const root = createParentNode(createHash('Root'), nodeA, nodeD);
        
        // Create the DFS array with correct indices
        const nodes: MerkleNode[] = [
            root,                           // 0
            nodeA, leafB, nodeC, leafG, leafH, // 1-5
            nodeD, leafE, nodeF, nodeI, leafJ // 6-11
        ];
        
        // Test parent relationships, especially challenging ones
        expect(findParentIndex(1, nodes)).toBe(0);  // A's parent is Root
        expect(findParentIndex(6, nodes)).toBe(0);  // D's parent is Root
        
        expect(findParentIndex(2, nodes)).toBe(1);  // B's parent is A
        expect(findParentIndex(3, nodes)).toBe(1);  // C's parent is A
        expect(findParentIndex(7, nodes)).toBe(6);  // E's parent is D
        expect(findParentIndex(8, nodes)).toBe(6);  // F's parent is D - tricky case
        
        expect(findParentIndex(4, nodes)).toBe(3);  // G's parent is C
        expect(findParentIndex(5, nodes)).toBe(3);  // H's parent is C
        expect(findParentIndex(9, nodes)).toBe(8);  // I's parent is F
        expect(findParentIndex(10, nodes)).toBe(8); // J's parent is F
    });
});
