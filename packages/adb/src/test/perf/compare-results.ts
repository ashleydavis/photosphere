import * as fs from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

interface PerformanceResults {
  metadata: {
    timestamp: string;
    totalFiles: number;
    testDurationMs: number;
    nodeVersion: string;
    platform: string;
    arch: string;
  };
  overall: {
    meanMs: number;
    medianMs: number;
    minMs: number;
    maxMs: number;
    p95Ms: number;
    p99Ms: number;
    totalTimeMs: number;
    averageTimePerFileMs: number;
  };
  scaling: {
    firstQuarterAverageMs: number;
    lastQuarterAverageMs: number;
    scalingRatio: number;
    classification: string;
  };
  trends: Array<{fileRange: string; meanMs: number; medianMs: number}>;
  scalePoints: Array<{size: number; averageMs: number}>;
  tree: {
    totalFiles: number;
    totalNodes: number;
    sortedRefs: number;
  };
}

/**
 * Load performance results from a JSON file
 */
function loadResults(filename: string): PerformanceResults {
  const filepath = join(__dirname, 'results', filename);
  if (!fs.existsSync(filepath)) {
    throw new Error(`Performance results file not found: ${filepath}`);
  }
  
  const content = fs.readFileSync(filepath, 'utf-8');
  return JSON.parse(content);
}

/**
 * Get all performance result files in the directory
 */
function getResultFiles(): string[] {
  const resultsDir = join(__dirname, 'results');
  if (!fs.existsSync(resultsDir)) {
    return [];
  }
  const files = fs.readdirSync(resultsDir)
    .filter(f => f.startsWith('performance-results-') && f.endsWith('.json'))
    .sort();
  return files;
}

/**
 * Calculate percentage change between two values
 */
function percentageChange(oldValue: number, newValue: number): string {
  const change = ((newValue - oldValue) / oldValue) * 100;
  const sign = change > 0 ? '+' : '';
  return `${sign}${change.toFixed(2)}%`;
}

/**
 * Compare two performance result sets
 */
function compareResults(baseline: PerformanceResults, current: PerformanceResults): void {
  console.log('🔍 Performance Comparison Results\n');
  
  // Test configuration check
  if (baseline.metadata.totalFiles !== current.metadata.totalFiles) {
    console.log('⚠️  WARNING: Different test sizes - comparison may not be meaningful');
    console.log(`   Baseline: ${baseline.metadata.totalFiles} files`);
    console.log(`   Current:  ${current.metadata.totalFiles} files\n`);
  }
  
  console.log(`📊 Baseline: ${new Date(baseline.metadata.timestamp).toLocaleString()}`);
  console.log(`📊 Current:  ${new Date(current.metadata.timestamp).toLocaleString()}\n`);
  
  // Overall performance comparison
  console.log('⚡ Overall Performance:');
  console.log(`   Mean time:    ${baseline.overall.meanMs.toFixed(4)}ms → ${current.overall.meanMs.toFixed(4)}ms (${percentageChange(baseline.overall.meanMs, current.overall.meanMs)})`);
  console.log(`   Median time:  ${baseline.overall.medianMs.toFixed(4)}ms → ${current.overall.medianMs.toFixed(4)}ms (${percentageChange(baseline.overall.medianMs, current.overall.medianMs)})`);
  console.log(`   95th percentile: ${baseline.overall.p95Ms.toFixed(4)}ms → ${current.overall.p95Ms.toFixed(4)}ms (${percentageChange(baseline.overall.p95Ms, current.overall.p95Ms)})`);
  console.log(`   Total time:   ${baseline.overall.totalTimeMs.toFixed(0)}ms → ${current.overall.totalTimeMs.toFixed(0)}ms (${percentageChange(baseline.overall.totalTimeMs, current.overall.totalTimeMs)})`);
  
  // Scaling comparison
  console.log('\n📈 Scaling Performance:');
  console.log(`   Scaling ratio: ${baseline.scaling.scalingRatio.toFixed(2)}x → ${current.scaling.scalingRatio.toFixed(2)}x (${percentageChange(baseline.scaling.scalingRatio, current.scaling.scalingRatio)})`);
  console.log(`   Classification: ${baseline.scaling.classification} → ${current.scaling.classification}`);
  
  // Performance verdict
  console.log('\n🎯 Performance Verdict:');
  const meanChange = ((current.overall.meanMs - baseline.overall.meanMs) / baseline.overall.meanMs) * 100;
  
  if (meanChange < -5) {
    console.log(`   🟢 IMPROVEMENT: ${Math.abs(meanChange).toFixed(1)}% faster overall`);
  } else if (meanChange > 5) {
    console.log(`   🔴 REGRESSION: ${meanChange.toFixed(1)}% slower overall`);
  } else {
    console.log(`   🟡 NEUTRAL: ${Math.abs(meanChange).toFixed(1)}% change (within acceptable range)`);
  }
  
  // Tree efficiency comparison (if same file count)
  if (baseline.metadata.totalFiles === current.metadata.totalFiles) {
    console.log('\n🌳 Tree Efficiency:');
    console.log(`   Tree nodes: ${baseline.tree.totalNodes} → ${current.tree.totalNodes}`);
    if (baseline.tree.totalNodes !== current.tree.totalNodes) {
      console.log('   ⚠️  Tree structure changed - this may indicate algorithmic changes');
    }
  }
}

/**
 * Main comparison function
 */
function main() {
  const args = process.argv.slice(2);
  
  if (args.length === 0) {
    // Auto-compare latest two results
    const files = getResultFiles();
    if (files.length < 2) {
      console.log('❌ Need at least 2 performance result files to compare');
      console.log('Available files:', files.length > 0 ? files : 'none');
      process.exit(1);
    }
    
    const baseline = loadResults(files[files.length - 2]);
    const current = loadResults(files[files.length - 1]);
    
    console.log(`Comparing latest two results:`);
    console.log(`  Baseline: ${files[files.length - 2]}`);
    console.log(`  Current:  ${files[files.length - 1]}\n`);
    
    compareResults(baseline, current);
    
  } else if (args.length === 2) {
    // Compare specified files
    const baseline = loadResults(args[0]);
    const current = loadResults(args[1]);
    
    console.log(`Comparing specified files:`);
    console.log(`  Baseline: ${args[0]}`);
    console.log(`  Current:  ${args[1]}\n`);
    
    compareResults(baseline, current);
    
  } else {
    console.log('Usage:');
    console.log('  bun run compare-results.ts                           # Compare latest two results');
    console.log('  bun run compare-results.ts <baseline> <current>      # Compare specific files');
    console.log('\nAvailable files:');
    getResultFiles().forEach(file => console.log(`  ${file}`));
  }
}

// Run if executed directly
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}

export { compareResults, loadResults, getResultFiles };
