//
// Compare different sorting techniques and show the differences
//

const originalFileNames = [
    'README.md',
    'assets/89171cd9-a652-4047-b869-1154bf2c95a1',
    'display/89171cd9-a652-4047-b869-1154bf2c95a1',
    'thumb/89171cd9-a652-4047-b869-1154bf2c95a1'
];

// Randomize the array using Fisher-Yates shuffle
const fileNames = [...originalFileNames];
for (let i = fileNames.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [fileNames[i], fileNames[j]] = [fileNames[j], fileNames[i]];
}

console.log('Input order (randomized):');
fileNames.forEach((name, index) => {
    console.log(`  ${index + 1}. ${name}`);
});

// Helper function to manually sort using a comparison function
function manualSort(arr: string[], compareFn: (a: string, b: string) => boolean): string[] {
    const sorted: string[] = [];
    for (const item of arr) {
        let insertIndex = 0;
        for (let i = 0; i < sorted.length; i++) {
            if (compareFn(item, sorted[i])) {
                break;
            }
            insertIndex = i + 1;
        }
        sorted.splice(insertIndex, 0, item);
    }
    return sorted;
}

// 1. Lexicographic comparison using < operator (what merkle tree USED to use)
console.log('\n================================================================================');
console.log('1. LEXICOGRAPHIC (< operator) - PREVIOUSLY USED BY MERKLE TREE');
console.log('================================================================================');
console.log('How it works:');
console.log('  - Uses JavaScript\'s < operator for string comparison');
console.log('  - Compares strings character-by-character using UTF-16 code units');
console.log('  - Uppercase letters (A-Z: 65-90) come before lowercase (a-z: 97-122)');
console.log('  - Very fast - direct byte comparison, no locale processing');
console.log('\nBenefits for merkle tree:');
console.log('  + Fastest performance - simple integer comparison');
console.log('  + Deterministic across all systems and locales');
console.log('  + No external dependencies or locale settings needed');
console.log('  + Consistent binary search behavior');
console.log('  - Order may not match user expectations (README before assets)');
console.log('\nSorted result:');
const sorted1 = manualSort(fileNames, (a, b) => a < b);
sorted1.forEach((name, index) => {
    console.log(`  ${index + 1}. ${name}`);
});

// 2. localeCompare (locale-aware, case-insensitive by default)
console.log('\n================================================================================');
console.log('2. LOCALE-AWARE (localeCompare)');
console.log('================================================================================');
console.log('How it works:');
console.log('  - Uses Unicode Collation Algorithm (UCA)');
console.log('  - Case-insensitive by default (a === A)');
console.log('  - Respects user\'s locale settings');
console.log('  - Handles accented characters properly (é, ñ, etc.)');
console.log('\nBenefits for merkle tree:');
console.log('  + More intuitive ordering for users (assets before README)');
console.log('  + Handles international characters correctly');
console.log('  + Case-insensitive grouping (README.md near readme.txt)');
console.log('  - Slower than lexicographic comparison');
console.log('  - May vary across different locales/systems');
console.log('  - Could cause sync issues between systems with different locales');
console.log('\nSorted result:');
const sorted2 = manualSort(fileNames, (a, b) => a.localeCompare(b) < 0);
sorted2.forEach((name, index) => {
    console.log(`  ${index + 1}. ${name}`);
});

// 3. localeCompare with case-sensitive option
console.log('\n================================================================================');
console.log('3. LOCALE-AWARE CASE-SENSITIVE (localeCompare variant)');
console.log('================================================================================');
console.log('How it works:');
console.log('  - Uses Unicode Collation Algorithm with case sensitivity');
console.log('  - Still respects locale but distinguishes case');
console.log('  - Typically lowercase before uppercase within same letter');
console.log('\nBenefits for merkle tree:');
console.log('  + Better international character handling than lexicographic');
console.log('  + More intuitive ordering for users');
console.log('  + Distinguishes case (unlike default localeCompare)');
console.log('  - Slower than lexicographic comparison');
console.log('  - May still vary across locales');
console.log('  - More complex implementation');
console.log('\nSorted result:');
const sorted3 = manualSort(fileNames, (a, b) => a.localeCompare(b, undefined, { sensitivity: 'variant' }) < 0);
sorted3.forEach((name, index) => {
    console.log(`  ${index + 1}. ${name}`);
});

// 4. Case-insensitive comparison
console.log('\n================================================================================');
console.log('4. CASE-INSENSITIVE (toLowerCase comparison)');
console.log('================================================================================');
console.log('How it works:');
console.log('  - Converts both strings to lowercase before comparing');
console.log('  - Then uses lexicographic comparison');
console.log('  - Simple implementation, predictable behavior');
console.log('\nBenefits for merkle tree:');
console.log('  + Fast (faster than locale-aware)');
console.log('  + More intuitive ordering (assets before README)');
console.log('  + Deterministic across systems');
console.log('  + Groups files regardless of case');
console.log('  - Extra toLowerCase() operation adds overhead');
console.log('  - May not handle all Unicode characters correctly');
console.log('  - Need secondary comparison for case when equal');
console.log('\nSorted result:');
const sorted4 = manualSort(fileNames, (a, b) => a.toLowerCase() < b.toLowerCase());
sorted4.forEach((name, index) => {
    console.log(`  ${index + 1}. ${name}`);
});

// 5. Natural sort (numeric-aware) - NOW USED BY MERKLE TREE
console.log('\n================================================================================');
console.log('5. NATURAL/NUMERIC-AWARE SORT (localeCompare numeric) - CURRENTLY USED BY MERKLE TREE');
console.log('================================================================================');
console.log('How it works:');
console.log('  - Treats consecutive digits as numbers, not individual characters');
console.log('  - "file2.txt" comes before "file10.txt" (not "file10" before "file2")');
console.log('  - Combines locale-awareness with numeric intelligence');
console.log('\nBenefits for merkle tree:');
console.log('  + Most human-friendly ordering for numbered files');
console.log('  + Handles versions correctly (v1, v2, v10, v20)');
console.log('  + Good for UUIDs and sequential file names');
console.log('  + Intuitive when browsing file lists');
console.log('  - Slowest option (complex parsing)');
console.log('  - May vary across locales');
console.log('  - Overkill if files don\'t have numbers');
console.log('\nSorted result:');
const sorted5 = manualSort(fileNames, (a, b) => a.localeCompare(b, undefined, { numeric: true }) < 0);
sorted5.forEach((name, index) => {
    console.log(`  ${index + 1}. ${name}`);
});

console.log('\n=== SUMMARY ===');
console.log('Merkle tree now uses: Natural/Numeric-aware sort (localeCompare with numeric: true)');
console.log('This provides intuitive ordering for both alphabetic and numeric file names.');
