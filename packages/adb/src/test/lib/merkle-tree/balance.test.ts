import { rotateRight, rotateLeft, rebalanceTree } from '../../../lib/merkle-tree';
import { node, leaf, expectNode } from './merkle-verify';

describe('balance', () => {

    test('right rotation', () => {
        /*
         * Before rotation:
         *     A
         *    / \
         *   B   D
         *  / \
         * C   E
         * 
         * After rotation:
         *     B
         *    / \
         *   C   A
         *      / \
         *     E   D
         */
        const C = leaf('C', 100);
        const E = leaf('E', 200);
        const D = leaf('D', 300);
        const B = node(C, E);
        const A = node(B, D);

        const result = rotateRight(A);
        expectNode(expect.getState().currentTestName!, result, {
            left: C,
            right: {
                left: E,
                right: D,                    
            },
        });
    });

    test('left rotation', () => {
        /*
         * Before rotation:
         *     A
         *    / \
         *   B   C
         *      / \
         *     D   E
         * 
         * After rotation:
         *     C
         *    / \
         *   A   E
         *  / \
         * B   D
         */
        const B = leaf('B', 100);
        const D = leaf('D', 200);
        const E = leaf('E', 300);
        const C = node(D, E);
        const A = node(B, C);

        const result = rotateLeft(A);
        expectNode(expect.getState().currentTestName!, result, {
            left: {
                left: B,
                right: D,
            },
            right: E,
        });
    });

    test('simple balanced tree requires no rotation', () => {
        /*
         * Balanced tree:
         *     A
         *    / \
         *   B   C
         */
        const C = leaf('C');
        const B = leaf('B');
        const A = node(B, C);

        const result = rebalanceTree(A);
        expectNode(expect.getState().currentTestName!, result, {
            left: B,
            right: C,
        });
    });

    test('slightly left heavy tree requires no rotation', () => {
        /*
         * Left heavy
         *     A
         *    / \
         *   B   E
         *  / \ 
         * C  D
         */
        const E = leaf('E');
        const D = leaf('D');
        const C = leaf('C');
        const B = node(C, D);
        const A = node(B, E);

        const result = rebalanceTree(A);
        expectNode(expect.getState().currentTestName!, result, {
            left: B,
            right: E,
        });
    });

    test('slightly right heavy tree requires rotation', () => {
        /*
         * Right heavy
         *     A
         *    / \
         *   B   C
         *      / \
         *     D   E
         */
        const B = leaf('B');
        const D = leaf('D');
        const E = leaf('E');
        const C = node(D, E);
        const A = node(B, C);

        const result = rebalanceTree(A);
        expectNode(expect.getState().currentTestName!, result, {
            left: {
                left: B,
                right: D,
            },
            right: E,
        });
    });

    test(`left heavy tree requires right rotation`, () => {
        /*
         * Heavily left-heavy tree:
         *         A
         *        / \
         *       B   C
         *      / \
         *     D   E
         *    / \
         *   F   G
         * 
         * After right rotation:
         *       B
         *      / \
         *     D   A
         *    / \ / \
         *   F G E   C
         */
        const F = leaf('F');
        const G = leaf('G');
        const D = node(F, G);
        const E = leaf('E');
        const B = node(D, E);
        const C = leaf('C');
        const A = node(B, C);

        const result = rebalanceTree(A);
        
        // Verify the structure after rebalancing
        expectNode(expect.getState().currentTestName!, result, {
            left: D,
            right: {
                left: E,
                right: C,
            },
        });
    });

    test(`right heavy tree requires left rotation`, () => {
        /*
         * Heavily right-heavy tree:
         *         A
         *        / \
         *       B   C
         *          / \
         *         D   E
         *            / \
         *           F   G
         * 
         * After left rotation:
         *       C
         *      / \
         *     A   E
         *    / \ / \
         *   B  D F  G
         */
        const B = leaf('B');
        const D = leaf('D');
        const F = leaf('F');
        const G = leaf('G');
        const E = node(F, G);
        const C = node(D, E);
        const A = node(B, C);

        const result = rebalanceTree(A);
        
        // Verify the structure after rebalancing
        expectNode(expect.getState().currentTestName!, result, {
            left: {
                left: B,
                right: D,
            },
            right: E,
        });
    });
});
