import { levenshteinDistance, fuzzyMatch } from '../../lib/fuzzy-match';

describe('levenshteinDistance', () => {
    test('returns 0 for identical strings', () => {
        expect(levenshteinDistance('abc', 'abc')).toBe(0);
    });

    test('returns 0 for two empty strings', () => {
        expect(levenshteinDistance('', '')).toBe(0);
    });

    test('returns length of non-empty string when other is empty', () => {
        expect(levenshteinDistance('abc', '')).toBe(3);
        expect(levenshteinDistance('', 'abc')).toBe(3);
    });

    test('counts a single substitution', () => {
        expect(levenshteinDistance('cat', 'bat')).toBe(1);
    });

    test('counts a single insertion', () => {
        expect(levenshteinDistance('cat', 'cats')).toBe(1);
    });

    test('counts a single deletion', () => {
        expect(levenshteinDistance('cats', 'cat')).toBe(1);
    });

    test('counts multiple edits', () => {
        expect(levenshteinDistance('kitten', 'sitting')).toBe(3);
    });

    test('is symmetric', () => {
        expect(levenshteinDistance('abc', 'xyz')).toBe(levenshteinDistance('xyz', 'abc'));
    });
});

describe('fuzzyMatch', () => {
    test('returns empty array when candidates is empty', () => {
        expect(fuzzyMatch('mydb', [])).toEqual([]);
    });

    test('skips exact match (distance 0)', () => {
        expect(fuzzyMatch('mydb', ['mydb'])).toEqual([]);
    });

    test('returns candidate within threshold', () => {
        // 'mydb' vs 'mydb2': distance 1, threshold max(3, floor(4/4))=3 → included
        expect(fuzzyMatch('mydb', ['mydb2'])).toContain('mydb2');
    });

    test('skips candidate beyond threshold', () => {
        // 'abc' vs 'zyxwvut': distance 7, threshold max(3,0)=3 → excluded
        expect(fuzzyMatch('abc', ['zyxwvut'])).toEqual([]);
    });

    test('is case-insensitive', () => {
        expect(fuzzyMatch('mydb', ['MyDB2'])).toContain('MyDB2');
    });

    test('returns multiple matches when several candidates qualify', () => {
        const results = fuzzyMatch('mydb', ['mydb1', 'mydb2', 'totallydifferent']);
        expect(results).toContain('mydb1');
        expect(results).toContain('mydb2');
        expect(results).not.toContain('totallydifferent');
    });
});
