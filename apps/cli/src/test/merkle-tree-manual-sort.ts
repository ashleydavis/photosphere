//
// Manual sorting using the exact same comparison as merkle tree
// Replicates the insertion logic from _addFile function
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

// Manually insert each file into the correct position using the < operator
// This replicates the exact logic from merkle tree _addFile function (line 445, 462)
const sortedFileNames: string[] = [];

for (const fileName of fileNames) {
    // Find the correct position to insert this file
    let insertIndex = 0;
    for (let i = 0; i < sortedFileNames.length; i++) {
        if (fileName < sortedFileNames[i]) {
            // Found the position where fileName should go
            break;
        }
        insertIndex = i + 1;
    }

    // Insert at the correct position
    sortedFileNames.splice(insertIndex, 0, fileName);
}

console.log('\nSorted order (manual insertion using < operator):');
sortedFileNames.forEach((name, index) => {
    console.log(`  ${index + 1}. ${name}`);
});
