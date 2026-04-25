
//
// Computes the Levenshtein edit distance between two strings using dynamic programming.
//
export function levenshteinDistance(a: string, b: string): number {
    const matrix: number[][] = [];

    for (let i = 0; i <= b.length; i++) {
        matrix[i] = [i];
    }

    for (let j = 0; j <= a.length; j++) {
        matrix[0][j] = j;
    }

    for (let i = 1; i <= b.length; i++) {
        for (let j = 1; j <= a.length; j++) {
            if (b[i - 1] === a[j - 1]) {
                matrix[i][j] = matrix[i - 1][j - 1];
            }
            else {
                matrix[i][j] = Math.min(
                    matrix[i - 1][j - 1] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j] + 1
                );
            }
        }
    }

    return matrix[b.length][a.length];
}

//
// Returns candidates whose Levenshtein edit distance from the query is within
// the threshold: distance > 0 && distance <= max(3, floor(query.length / 4)).
// Comparison is case-insensitive.
//
export function fuzzyMatch(query: string, candidates: string[]): string[] {
    const lowerQuery = query.toLowerCase();
    const threshold = Math.max(3, Math.floor(lowerQuery.length / 4));
    return candidates.filter(candidate => {
        const distance = levenshteinDistance(lowerQuery, candidate.toLowerCase());
        return distance > 0 && distance <= threshold;
    });
}
