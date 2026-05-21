import * as crypto from 'crypto';
import {
    addItem,
    updateItem,
    deleteItem,
    findItemNode,
    createTree,
    HashedItem,
} from '../src/lib/merkle-tree';

// Creates a HashedItem with a sha256 hash of the given content.
function createHashedItem(name: string, content: string = name): HashedItem {
    const hash = crypto.createHash('sha256')
        .update(content)
        .digest();
    return {
        name,
        hash,
        length: content.length,
        lastModified: new Date(),
    };
}

// Measures the execution time of a synchronous function and returns the result and time in ms.
function measureTime<T>(fn: () => T): [T, number] {
    const start = process.hrtime.bigint();
    const result = fn();
    const end = process.hrtime.bigint();
    const timeInMs = Number(end - start) / 1e6;
    return [result, timeInMs];
}

// Generates an array of sequential file names with the given prefix.
function generateFileNames(count: number, prefix: string = 'file-'): string[] {
    return Array.from({ length: count }, (_, index) => `${prefix}${index}.txt`);
}

// Benchmarks adding files to the tree at various sizes and checks time-per-file threshold.
async function benchmarkAddFiles(): Promise<boolean> {
    console.log('benchmarkAddFiles: starting');
    const sizes = [10, 100, 1000, 5000, 10000];
    let passed = true;

    for (const size of sizes) {
        const fileNames = generateFileNames(size);
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");

        const [resultTree, time] = measureTime(() => {
            for (const fileName of fileNames) {
                tree = addItem(tree, createHashedItem(fileName));
            }
            return tree;
        });

        const timePerFile = time / size;
        if (timePerFile >= 8) {
            console.log(`  FAIL size=${size}: timePerFile=${timePerFile.toFixed(3)}ms >= 8ms threshold`);
            passed = false;
        }
        else {
            console.log(`  size=${size}: total=${time.toFixed(2)}ms, perFile=${timePerFile.toFixed(3)}ms`);
        }

        if (!resultTree) {
            console.log(`  FAIL size=${size}: tree is undefined`);
            passed = false;
        }
    }

    if (passed) {
        console.log('PASS benchmarkAddFiles');
    }
    else {
        console.log('FAIL benchmarkAddFiles');
    }

    return passed;
}

// Benchmarks updating files at three positions in a 10000-file tree, threshold 10ms per update.
async function benchmarkUpdateFiles(): Promise<boolean> {
    console.log('benchmarkUpdateFiles: starting');
    const fileCount = 10000;
    const fileNames = generateFileNames(fileCount);
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");

    for (const fileName of fileNames) {
        tree = addItem(tree, createHashedItem(fileName));
    }

    const indicesToTest = [0, Math.floor(fileCount / 2), fileCount - 1];
    let passed = true;

    for (const index of indicesToTest) {
        const fileName = fileNames[index];
        const updatedContent = `Updated content for ${fileName}`;

        const [, time] = measureTime(() => {
            return updateItem(tree, createHashedItem(fileName, updatedContent));
        });

        if (time >= 10) {
            console.log(`  FAIL index=${index}: time=${time.toFixed(2)}ms >= 10ms threshold`);
            passed = false;
        }
        else {
            console.log(`  index=${index}: time=${time.toFixed(2)}ms`);
        }
    }

    if (passed) {
        console.log('PASS benchmarkUpdateFiles');
    }
    else {
        console.log('FAIL benchmarkUpdateFiles');
    }

    return passed;
}

// Benchmarks deleting files at three positions in a 10000-file tree, threshold 20ms per delete.
async function benchmarkDeleteFiles(): Promise<boolean> {
    console.log('benchmarkDeleteFiles: starting');
    const fileCount = 10000;
    const fileNames = generateFileNames(fileCount);
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");

    for (const fileName of fileNames) {
        tree = addItem(tree, createHashedItem(fileName));
    }

    const indicesToTest = [0, Math.floor(fileCount / 2), fileCount - 1];
    let passed = true;

    for (const index of indicesToTest) {
        const fileName = fileNames[index];

        const [, time] = measureTime(() => {
            deleteItem(tree!, fileName);
        });

        const node = findItemNode(tree, fileName);
        if (node !== undefined) {
            console.log(`  FAIL index=${index}: node still found after delete`);
            passed = false;
        }

        if (time >= 20) {
            console.log(`  FAIL index=${index}: time=${time.toFixed(2)}ms >= 20ms threshold`);
            passed = false;
        }
        else {
            console.log(`  index=${index}: time=${time.toFixed(2)}ms`);
        }
    }

    if (passed) {
        console.log('PASS benchmarkDeleteFiles');
    }
    else {
        console.log('FAIL benchmarkDeleteFiles');
    }

    return passed;
}

// Benchmarks tree depth impact by comparing update scaling between 1000 and 10000-file trees.
async function benchmarkTreeDepthImpact(): Promise<boolean> {
    console.log('benchmarkTreeDepthImpact: starting');
    const treeSizes = [1000, 10000];
    const results: Record<number, { addTime: number; updateTime: number }> = {};
    let passed = true;

    for (const size of treeSizes) {
        const fileNames = generateFileNames(size);
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");

        const [resultTree, addTime] = measureTime(() => {
            for (const fileName of fileNames) {
                tree = addItem(tree, createHashedItem(fileName));
            }
            return tree;
        });

        const middleFileName = fileNames[Math.floor(size / 2)];
        const [, updateTime] = measureTime(() => {
            return updateItem(resultTree, createHashedItem(middleFileName, 'updated content'));
        });

        results[size] = { addTime, updateTime };
        console.log(`  size=${size}: addTime=${addTime.toFixed(2)}ms, updateTime=${updateTime.toFixed(2)}ms`);
    }

    for (let i = 1; i < treeSizes.length; i++) {
        const currentSize = treeSizes[i];
        const previousSize = treeSizes[i - 1];
        const sizeRatio = currentSize / previousSize;
        const timeRatio = results[currentSize].updateTime / results[previousSize].updateTime;

        if (timeRatio >= sizeRatio * 2) {
            console.log(`  FAIL timeRatio=${timeRatio.toFixed(3)} >= sizeRatio*2=${(sizeRatio * 2).toFixed(3)}`);
            passed = false;
        }
    }

    const firstAvgTime = results[treeSizes[0]].updateTime;
    const lastNormalized = results[treeSizes[treeSizes.length - 1]].updateTime / treeSizes[treeSizes.length - 1] * treeSizes[0];

    if (lastNormalized > firstAvgTime * 2) {
        console.log(`  FAIL normalized update time ${lastNormalized.toFixed(3)}ms > firstAvgTime*2=${(firstAvgTime * 2).toFixed(3)}ms`);
        passed = false;
    }

    if (passed) {
        console.log('PASS benchmarkTreeDepthImpact');
    }
    else {
        console.log('FAIL benchmarkTreeDepthImpact');
    }

    return passed;
}

// Benchmarks batch add/update/delete on a 1000-file baseline tree; thresholds 1ms per update and delete.
async function benchmarkBatchOperations(): Promise<boolean> {
    console.log('benchmarkBatchOperations: starting');
    const baselineCount = 1000;
    const baseFileNames = generateFileNames(baselineCount);
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");

    for (const fileName of baseFileNames) {
        tree = addItem(tree, createHashedItem(fileName));
    }

    const addBatchSize = 100;
    const newFileNames = generateFileNames(addBatchSize, 'new-file-');

    const [treeAfterAdd] = measureTime(() => {
        let currentTree = tree;
        for (const fileName of newFileNames) {
            currentTree = addItem(currentTree, createHashedItem(fileName));
        }
        return currentTree;
    });

    const updateBatchSize = 100;
    const filesToUpdate = baseFileNames.slice(0, updateBatchSize);

    const [, updateBatchTime] = measureTime(() => {
        return filesToUpdate.map(fileName =>
            updateItem(treeAfterAdd, createHashedItem(fileName, `updated-${fileName}`))
        );
    });

    const deleteBatchSize = 100;
    const filesToDelete = baseFileNames.slice(updateBatchSize, updateBatchSize + deleteBatchSize);

    const [, deleteBatchTime] = measureTime(() => {
        filesToDelete.forEach(fileName => deleteItem(treeAfterAdd!, fileName));
    });

    const avgTimePerUpdate = updateBatchTime / updateBatchSize;
    const avgTimePerDelete = deleteBatchTime / deleteBatchSize;

    console.log(`  avgTimePerUpdate=${avgTimePerUpdate.toFixed(3)}ms, avgTimePerDelete=${avgTimePerDelete.toFixed(3)}ms`);

    let passed = true;

    if (avgTimePerUpdate >= 1) {
        console.log(`  FAIL avgTimePerUpdate=${avgTimePerUpdate.toFixed(3)}ms >= 1ms threshold`);
        passed = false;
    }

    if (avgTimePerDelete >= 1) {
        console.log(`  FAIL avgTimePerDelete=${avgTimePerDelete.toFixed(3)}ms >= 1ms threshold`);
        passed = false;
    }

    if (passed) {
        console.log('PASS benchmarkBatchOperations');
    }
    else {
        console.log('FAIL benchmarkBatchOperations');
    }

    return passed;
}

// Runs all benchmarks, prints a summary, and exits with code 1 if any failed.
async function main(): Promise<void> {
    const results = await Promise.all([
        benchmarkAddFiles(),
        benchmarkUpdateFiles(),
        benchmarkDeleteFiles(),
        benchmarkTreeDepthImpact(),
        benchmarkBatchOperations(),
    ]);

    const passCount = results.filter(result => result).length;
    const totalCount = results.length;
    console.log(`\n${passCount}/${totalCount} passed`);

    if (passCount < totalCount) {
        process.exit(1);
    }
}

main();
