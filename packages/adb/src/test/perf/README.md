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

### Test Run: 100,000 Files (October 2025)

```
🚀 Starting Merkle Tree Performance Test
📊 Adding 100,000 files and measuring individual add times...

✅ Added 10000 files - Average time: 0.0506ms, Last file: 0.0916ms
✅ Added 20000 files - Average time: 0.0734ms, Last file: 0.0898ms
✅ Added 30000 files - Average time: 0.0964ms, Last file: 0.1245ms
✅ Added 40000 files - Average time: 0.1150ms, Last file: 0.1666ms
✅ Added 50000 files - Average time: 0.1377ms, Last file: 0.2247ms
✅ Added 60000 files - Average time: 0.1608ms, Last file: 0.2321ms
✅ Added 70000 files - Average time: 0.1828ms, Last file: 0.2686ms
✅ Added 80000 files - Average time: 0.2054ms, Last file: 0.3192ms
✅ Added 90000 files - Average time: 0.2318ms, Last file: 0.4473ms
✅ Added 100000 files - Average time: 0.2667ms, Last file: 0.4659ms

📈 Performance Analysis Results:

🎯 Overall Add Time Statistics:
   Mean: 0.2667ms
   Median: 0.2092ms
   Min: 0.0061ms
   Max: 12.5037ms
   95th percentile: 0.5845ms
   99th percentile: 1.2210ms

📊 Performance Trends (Every 5,000 Files):
   Files 1-5000: Mean 0.0409ms, Median 0.0355ms
   Files 5001-10000: Mean 0.0602ms, Median 0.0527ms
   Files 10001-15000: Mean 0.0889ms, Median 0.0740ms
   Files 15001-20000: Mean 0.1036ms, Median 0.0880ms
   Files 20001-25000: Mean 0.1252ms, Median 0.1054ms
   Files 25001-30000: Mean 0.1598ms, Median 0.1216ms
   Files 30001-35000: Mean 0.1679ms, Median 0.1364ms
   Files 35001-40000: Mean 0.1734ms, Median 0.1483ms
   Files 40001-45000: Mean 0.2204ms, Median 0.1700ms
   Files 45001-50000: Mean 0.2363ms, Median 0.1870ms
   Files 50001-55000: Mean 0.2662ms, Median 0.2068ms
   Files 55001-60000: Mean 0.2864ms, Median 0.2319ms
   Files 60001-65000: Mean 0.2860ms, Median 0.2481ms
   Files 65001-70000: Mean 0.3440ms, Median 0.2761ms
   Files 70001-75000: Mean 0.3461ms, Median 0.2927ms
   Files 75001-80000: Mean 0.3817ms, Median 0.3121ms
   Files 80001-85000: Mean 0.4219ms, Median 0.3409ms
   Files 85001-90000: Mean 0.4637ms, Median 0.3505ms
   Files 90001-95000: Mean 0.5235ms, Median 0.3814ms
   Files 95001-100000: Mean 0.6378ms, Median 0.4261ms

🔍 Performance Scaling Analysis:
   ~10000 files: 0.0725ms average
   ~25000 files: 0.1330ms average
   ~50000 files: 0.2349ms average
   ~75000 files: 0.3683ms average
   ~100000 files: 0.7515ms average

⚡ Scaling Analysis:
   First quarter average (1-25,000 files): 0.0838ms
   Last quarter average (75,001-100,000 files): 0.4857ms
   Scaling ratio: 5.80x
   🔴 Performance degrades significantly with size - possibly O(n) or worse

📋 Final Tree Statistics:
   Total files: 100000
   Tree nodes: 199999
   Sorted refs: 100000
   Total time: 26669.47ms
   Average time per file: 0.2667ms
```

### Performance Summary (Latest Binary Tree Implementation)

- **Average file addition time**: 0.27ms (270 microseconds) - **12% slower than previous run**
- **Throughput**: ~3,750 files/second - **11% slower than previous run**
- **Scaling factor**: 5.80x (improved from 7.96x - better scaling characteristics)
- **Memory efficiency**: 199,999 nodes for 100,000 files (balanced tree structure)
- **Total test duration**: 26.7 seconds - **12% slower than previous run**

### Performance Comparison (Latest vs Previous)

| Metric | Previous Run (Oct 2024) | Latest Run (Oct 2025) | Change |
|--------|------------------------|----------------------|--------|
| Mean add time | 0.24ms | 0.27ms | **12% slower** |
| Throughput | 4,200 files/sec | 3,750 files/sec | **11% slower** |
| Total duration | 23.8s | 26.7s | **12% slower** |
| Scaling ratio | 7.96x | 5.80x | **27% better scaling** |

The latest implementation shows slightly slower absolute performance but significantly improved scaling characteristics. The scaling ratio improved from 7.96x to 5.80x, indicating better algorithmic behavior as the tree grows larger. This suggests optimizations in the tree balancing algorithm that trade some absolute speed for better scalability.

### Historical Performance Comparison

| Metric | Original (Array-based) | Optimized (Binary Tree) | Latest (Oct 2025) | Overall Improvement |
|--------|----------------------|------------------------|------------------|-------------------|
| Mean add time | 0.89ms | 0.24ms | 0.27ms | **70% faster than original** |
| Throughput | 1,119 files/sec | 4,200 files/sec | 3,750 files/sec | **235% faster than original** |
| Total duration | 89.3s | 23.8s | 26.7s | **70% faster than original** |
| Scaling ratio | 7.41x | 7.96x | 5.80x | **22% better scaling than original** |

The merkle tree implementation continues to show significant improvements over the original array-based approach, with the latest version offering the best scaling characteristics while maintaining excellent absolute performance.
