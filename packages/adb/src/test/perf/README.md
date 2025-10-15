# Merkle Tree Performance Test

This directory contains a performance testing script for the Merkle Tree `addFile` operation.

## Overview

The performance test (`test-merkle-performance.ts`) measures:
- Average time to add a file to the merkle tree
- How performance scales as more files are added (1-1000 files)
- Statistical analysis of add times (min, max, median, percentiles)
- Performance trend analysis to determine algorithmic complexity

## Running the Test

```bash
cd packages/adb
bun run src/test/perf/test-merkle-performance.ts
```

## Comparing Performance Results

The test automatically saves detailed performance data to JSON files for tracking changes over time:

### Baseline Performance
A baseline performance file (`baseline-performance.json`) captures the current implementation's performance with 100,000 files for reference comparisons.

### Auto-compare latest two results:
```bash
bun run src/test/perf/compare-results.ts
```

### Compare specific result files:
```bash
bun run src/test/perf/compare-results.ts 2024-10-15T10-30-00-000Z.json 2024-10-15T11-45-00-000Z.json
```

## JSON Output Format

Each test run saves comprehensive performance data including:

- **Metadata**: Timestamp, test configuration, system info
- **Overall Stats**: Mean, median, percentiles, total time
- **Scaling Analysis**: Quarter comparisons, scaling ratio, classification
- **Performance Trends**: Detailed breakdown every 5% of files
- **Scale Points**: Performance at 10%, 25%, 50%, 75%, 100% of files
- **Tree Stats**: Node count, structure efficiency

Example output structure:
```json
{
  "metadata": {
    "timestamp": "2024-10-15T10:30:00.000Z",
    "totalFiles": 100000,
    "testDurationMs": 88174.59,
    "nodeVersion": "v20.x.x",
    "platform": "linux",
    "arch": "x64"
  },
  "overall": {
    "meanMs": 0.8817,
    "medianMs": 0.7741,
    "p95Ms": 2.2134,
    "p99Ms": 4.5223,
    "totalTimeMs": 88174.59,
    "averageTimePerFileMs": 0.8817
  },
  "scaling": {
    "scalingRatio": 7.34,
    "classification": "poor"
  }
  // ... additional detailed data
}
```

## Test Details

The test:
1. Creates an empty merkle tree
2. Generates 1000 random files with varying sizes (1KB-100KB)
3. Adds each file individually while measuring the time
4. Analyzes performance trends and scaling characteristics

## Expected Output

The script provides:
- Real-time progress updates every 100 files
- Comprehensive statistics (mean, median, percentiles)
- Performance trend analysis by file count segments
- Scaling analysis to determine if performance is O(log n) or worse
- Final tree statistics

## Interpreting Results

### Performance Scaling
- **Green (🟢)**: Scaling ratio < 1.5x → Good O(log n) performance
- **Yellow (🟡)**: Scaling ratio 1.5-3x → Moderate scaling
- **Red (🔴)**: Scaling ratio > 3x → Poor scaling, possibly O(n)

### Key Metrics
- **Mean time**: Average time per file addition
- **Scaling ratio**: Performance difference between first 250 and last 250 files
- **95th/99th percentile**: Worst-case performance bounds

## Benchmark Results

### Test Run: 100,000 Files (October 2024)

```
🚀 Starting Merkle Tree Performance Test
📊 Adding 100,000 files and measuring individual add times...

✅ Added 10000 files - Average time: 0.0811ms, Last file: 0.1188ms
✅ Added 20000 files - Average time: 0.1603ms, Last file: 0.2400ms
✅ Added 30000 files - Average time: 0.2487ms, Last file: 0.4802ms
✅ Added 40000 files - Average time: 0.3251ms, Last file: 0.5269ms
✅ Added 50000 files - Average time: 0.4344ms, Last file: 0.5715ms
✅ Added 60000 files - Average time: 0.5625ms, Last file: 2.2601ms
✅ Added 70000 files - Average time: 0.6623ms, Last file: 0.6943ms
✅ Added 80000 files - Average time: 0.7323ms, Last file: 0.9057ms
✅ Added 90000 files - Average time: 0.8074ms, Last file: 1.3326ms
✅ Added 100000 files - Average time: 0.8934ms, Last file: 15.1041ms

📈 Performance Analysis Results:

🎯 Overall Add Time Statistics:
   Mean: 0.8934ms
   Median: 0.7868ms
   Min: 0.0043ms
   Max: 22.4117ms
   95th percentile: 2.2957ms
   99th percentile: 4.5723ms

📊 Performance Trends (Every 5,000 Files):
   Files 1-5000: Mean 0.0470ms, Median 0.0392ms
   Files 5001-10000: Mean 0.1153ms, Median 0.0956ms
   Files 10001-15000: Mean 0.2168ms, Median 0.1730ms
   Files 15001-20000: Mean 0.2623ms, Median 0.2209ms
   Files 20001-25000: Mean 0.3708ms, Median 0.2947ms
   Files 25001-30000: Mean 0.4801ms, Median 0.3861ms
   Files 30001-35000: Mean 0.5707ms, Median 0.4681ms
   Files 35001-40000: Mean 0.5376ms, Median 0.4432ms
   Files 40001-45000: Mean 0.8379ms, Median 0.6524ms
   Files 45001-50000: Mean 0.9058ms, Median 0.7648ms
   Files 50001-55000: Mean 1.1098ms, Median 0.8505ms
   Files 55001-60000: Mean 1.2957ms, Median 0.8877ms
   Files 60001-65000: Mean 1.3757ms, Median 1.0443ms
   Files 65001-70000: Mean 1.1462ms, Median 0.8622ms
   Files 70001-75000: Mean 1.0922ms, Median 0.8679ms
   Files 75001-80000: Mean 1.3524ms, Median 0.9990ms
   Files 80001-85000: Mean 1.3796ms, Median 1.0323ms
   Files 85001-90000: Mean 1.4375ms, Median 1.1394ms
   Files 90001-95000: Mean 1.6128ms, Median 1.2831ms
   Files 95001-100000: Mean 1.7217ms, Median 1.3964ms

🔍 Performance Scaling Analysis:
   ~10000 files: 0.1345ms average
   ~25000 files: 0.4003ms average
   ~50000 files: 0.9509ms average
   ~75000 files: 1.1845ms average
   ~100000 files: 1.5595ms average

⚡ Scaling Analysis:
   First quarter average (1-25,000 files): 0.2024ms
   Last quarter average (75,001-100,000 files): 1.5008ms
   Scaling ratio: 7.41x
   🔴 Performance degrades significantly with size - possibly O(n) or worse

📋 Final Tree Statistics:
   Total files: 100000
   Tree nodes: 199999
   Sorted refs: 100000
   Total time: 89338.76ms
   Average time per file: 0.8934ms
```

### Performance Summary

- **Average file addition time**: 0.89ms (890 microseconds)
- **Throughput**: ~1,119 files/second
- **Scaling factor**: 7.41x (poor scaling - O(n) characteristics)
- **Memory efficiency**: 199,999 nodes for 100,000 files (balanced tree structure)
- **Total test duration**: 89.3 seconds

The performance analysis reveals concerning scaling characteristics at larger sizes. While individual file additions remain under 1ms on average, the 7.41x scaling ratio indicates the current implementation exhibits O(n) behavior rather than the expected O(log n) for a balanced tree. This suggests potential optimization opportunities in the merkle tree implementation.
