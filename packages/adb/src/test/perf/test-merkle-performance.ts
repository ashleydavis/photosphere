import * as crypto from 'crypto';
import { fileURLToPath } from 'url';
import { dirname } from 'path';
import * as fs from 'fs';
import { 
  addFile, 
  FileHash,
  createTree,
} from '../../lib/merkle-tree';

/**
 * Configuration: Number of files to add to the merkle tree
 */
const TOTAL_FILES = 100_000;

/**
 * Helper function to create a file hash with random content
 */
function createRandomFileHash(fileName: string): FileHash {
  // Generate random content of varying sizes (1KB to 100KB)
  const contentSize = Math.floor(Math.random() * 99 * 1024) + 1024;
  const content = crypto.randomBytes(contentSize);
  
  const hash = crypto.createHash('sha256')
    .update(content)
    .digest();
    
  return {
    fileName,
    hash,
    length: content.length,
    lastModified: new Date(),
  };
}

/**
 * Helper function to measure execution time in milliseconds
 */
function measureTime<T>(fn: () => T): [T, number] {
  const start = process.hrtime.bigint();
  const result = fn();
  const end = process.hrtime.bigint();
  const timeInMs = Number(end - start) / 1e6; // Convert ns to ms
  return [result, timeInMs];
}

/**
 * Generate random file names
 */
function generateRandomFileName(index: number): string {
  const extensions = ['.txt', '.jpg', '.pdf', '.doc', '.mp4', '.png', '.json'];
  const extension = extensions[Math.floor(Math.random() * extensions.length)];
  const randomSuffix = Math.random().toString(36).substring(2, 8);
  return `file-${index}-${randomSuffix}${extension}`;
}

/**
 * Calculate statistics for a series of numbers
 */
function calculateStats(numbers: number[]) {
  const sorted = [...numbers].sort((a, b) => a - b);
  const sum = numbers.reduce((acc, n) => acc + n, 0);
  const mean = sum / numbers.length;
  
  return {
    min: Math.min(...numbers),
    max: Math.max(...numbers),
    mean,
    median: sorted[Math.floor(sorted.length / 2)],
    p95: sorted[Math.floor(sorted.length * 0.95)],
    p99: sorted[Math.floor(sorted.length * 0.99)],
  };
}

/**
 * Main performance testing function
 */
export function testMerkleTreePerformance() {
  console.log('🚀 Starting Merkle Tree Performance Test');
  console.log(`📊 Adding ${TOTAL_FILES.toLocaleString()} files and measuring individual add times...\n`);

  // Create initial tree
  let tree = createTree("12345678-1234-5678-9abc-123456789abc");
  
  // Arrays to store timing data
  const addTimes: number[] = [];
  const cumulativeTimes: number[] = [];
  const fileCounts: number[] = [];
  
  let totalTime = 0;
  
  // Add files one by one, measuring each addition
  for (let i = 1; i <= TOTAL_FILES; i++) {
    const fileName = generateRandomFileName(i);
    const fileHash = createRandomFileHash(fileName);
    
    const [newTree, addTime] = measureTime(() => {
      return addFile(tree, fileHash);
    });
    
    tree = newTree;
    totalTime += addTime;
    
    addTimes.push(addTime);
    cumulativeTimes.push(totalTime);
    fileCounts.push(i);
    
    // Print progress every 10% of files
    if (i % Math.floor(TOTAL_FILES / 10) === 0) {
      const avgTime = totalTime / i;
      console.log(`✅ Added ${i} files - Average time: ${avgTime.toFixed(4)}ms, Last file: ${addTime.toFixed(4)}ms`);
    }
  }
  
  console.log('\n📈 Performance Analysis Results:\n');
  
  // Overall statistics
  const stats = calculateStats(addTimes);
  console.log('🎯 Overall Add Time Statistics:');
  console.log(`   Mean: ${stats.mean.toFixed(4)}ms`);
  console.log(`   Median: ${stats.median.toFixed(4)}ms`);
  console.log(`   Min: ${stats.min.toFixed(4)}ms`);
  console.log(`   Max: ${stats.max.toFixed(4)}ms`);
  console.log(`   95th percentile: ${stats.p95.toFixed(4)}ms`);
  console.log(`   99th percentile: ${stats.p99.toFixed(4)}ms`);
  
  // Analyze performance trends
  const trendInterval = Math.floor(TOTAL_FILES / 20); // Every 5% of files
  console.log(`\n📊 Performance Trends (Every ${trendInterval.toLocaleString()} Files):`);
  
  for (let i = trendInterval; i <= TOTAL_FILES; i += trendInterval) {
    const start = i - trendInterval;
    const end = Math.min(i, addTimes.length);
    const segmentTimes = addTimes.slice(start, end);
    
    if (segmentTimes.length > 0) {
      const segmentStats = calculateStats(segmentTimes);
      console.log(`   Files ${start + 1}-${end}: Mean ${segmentStats.mean.toFixed(4)}ms, Median ${segmentStats.median.toFixed(4)}ms`);
    }
  }
  
  // Analyze if there's a correlation between file count and add time
  console.log('\n🔍 Performance Scaling Analysis:');
  
  // Calculate average time for different tree sizes
  const sizePoints = [
    Math.floor(TOTAL_FILES * 0.1),  // 10%
    Math.floor(TOTAL_FILES * 0.25), // 25%
    Math.floor(TOTAL_FILES * 0.5),  // 50%
    Math.floor(TOTAL_FILES * 0.75), // 75%
    TOTAL_FILES                     // 100%
  ];
  sizePoints.forEach(size => {
    const windowSize = Math.floor(TOTAL_FILES * 0.01); // 1% window
    const windowStart = Math.max(0, size - windowSize);
    const windowEnd = Math.min(addTimes.length, size + windowSize);
    const windowTimes = addTimes.slice(windowStart, windowEnd);
    const avgTime = windowTimes.reduce((sum, time) => sum + time, 0) / windowTimes.length;
    console.log(`   ~${size} files: ${avgTime.toFixed(4)}ms average`);
  });
  
  // Calculate theoretical complexity indicators
  const quarterSize = Math.floor(TOTAL_FILES / 4);
  const firstQuarterAvg = addTimes.slice(0, quarterSize).reduce((sum, time) => sum + time, 0) / quarterSize;
  const lastQuarterAvg = addTimes.slice(-quarterSize).reduce((sum, time) => sum + time, 0) / quarterSize;
  const scalingRatio = lastQuarterAvg / firstQuarterAvg;
  
  console.log('\n⚡ Scaling Analysis:');
  console.log(`   First quarter average (1-${quarterSize.toLocaleString()} files): ${firstQuarterAvg.toFixed(4)}ms`);
  console.log(`   Last quarter average (${(TOTAL_FILES - quarterSize + 1).toLocaleString()}-${TOTAL_FILES.toLocaleString()} files): ${lastQuarterAvg.toFixed(4)}ms`);
  console.log(`   Scaling ratio: ${scalingRatio.toFixed(2)}x`);
  
  if (scalingRatio < 1.5) {
    console.log('   🟢 Performance scales well - likely O(log n) complexity');
  } else if (scalingRatio < 3) {
    console.log('   🟡 Moderate performance scaling - between O(log n) and O(n)');
  } else {
    console.log('   🔴 Performance degrades significantly with size - possibly O(n) or worse');
  }
  
  // Final tree statistics
  console.log('\n📋 Final Tree Statistics:');
  console.log(`   Total files: ${tree.metadata.totalFiles}`);
  console.log(`   Tree nodes: ${tree.sortRoot?.nodeCount || 0}`);
  console.log(`   Total time: ${totalTime.toFixed(2)}ms`);
  console.log(`   Average time per file: ${(totalTime / TOTAL_FILES).toFixed(4)}ms`);
  
  // Create comprehensive performance results object
  const performanceResults = {
    metadata: {
      timestamp: new Date().toISOString(),
      totalFiles: TOTAL_FILES,
      testDurationMs: totalTime,
      nodeVersion: process.version,
      platform: process.platform,
      arch: process.arch
    },
    overall: {
      meanMs: stats.mean,
      medianMs: stats.median,
      minMs: stats.min,
      maxMs: stats.max,
      p95Ms: stats.p95,
      p99Ms: stats.p99,
      totalTimeMs: totalTime,
      averageTimePerFileMs: totalTime / TOTAL_FILES
    },
    scaling: {
      firstQuarterAverageMs: firstQuarterAvg,
      lastQuarterAverageMs: lastQuarterAvg,
      scalingRatio: scalingRatio,
      classification: scalingRatio < 1.5 ? 'excellent' : scalingRatio < 3 ? 'moderate' : 'poor'
    },
    trends: [] as Array<{fileRange: string, meanMs: number, medianMs: number}>,
    scalePoints: [] as Array<{size: number, averageMs: number}>,
    tree: {
      totalFiles: tree.metadata.totalFiles,
      totalNodes: tree.sortRoot?.nodeCount || 0,
    }
  };

  // Add trend data
  for (let i = trendInterval; i <= TOTAL_FILES; i += trendInterval) {
    const start = i - trendInterval;
    const end = Math.min(i, addTimes.length);
    const segmentTimes = addTimes.slice(start, end);
    
    if (segmentTimes.length > 0) {
      const segmentStats = calculateStats(segmentTimes);
      performanceResults.trends.push({
        fileRange: `${start + 1}-${end}`,
        meanMs: segmentStats.mean,
        medianMs: segmentStats.median
      });
    }
  }

  // Add scale point data
  sizePoints.forEach(size => {
    const windowSize = Math.floor(TOTAL_FILES * 0.01);
    const windowStart = Math.max(0, size - windowSize);
    const windowEnd = Math.min(addTimes.length, size + windowSize);
    const windowTimes = addTimes.slice(windowStart, windowEnd);
    const avgTime = windowTimes.reduce((sum, time) => sum + time, 0) / windowTimes.length;
    
    performanceResults.scalePoints.push({
      size: size,
      averageMs: avgTime
    });
  });

  // Save results to JSON file
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const filename = `${timestamp}.json`;
  const filepath = `src/test/perf/results/${filename}`;
  
  try {
    fs.writeFileSync(filepath, JSON.stringify(performanceResults, null, 2));
    console.log(`\n💾 Performance results saved to: ${filepath}`);
  } catch (error) {
    console.error(`\n❌ Failed to save performance results: ${error}`);
  }
  
  return {
    addTimes,
    stats,
    scalingRatio,
    totalTime,
    finalTree: tree,
    performanceResults
  };
}

// ESM setup for checking if script is run directly
const __filename = fileURLToPath(import.meta.url);

if (process.argv[1] === __filename) {
  try {
    testMerkleTreePerformance();
  } catch (error) {
    console.error('❌ Error running performance test:', error);
    process.exit(1);
  }
}

