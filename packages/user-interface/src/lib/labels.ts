//
// Removes duplicate labels while preserving their original order.
//
export function dedupeLabels(labels: string[]): string[] {
    return [...new Set(labels)];
}
