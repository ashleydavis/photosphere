import { Command, Option } from 'commander';
import { MediaFileDatabase } from 'api';
import { createStorage, loadEncryptionKeys, pathJoin } from 'storage';
import { log } from 'utils';
import { configureLog } from '../lib/log';

interface IDebugCommandOptions {
  meta?: string;
  key?: string;
  verbose?: boolean;
}

const metaOption = new Option('-m, --meta <db-metadata-dir>', 'The directory in which to store asset database metadata.');
const keyOption = new Option('-k, --key <keyfile>', 'Path to the private key file for encryption.');
const verboseOption = new Option('-v, --verbose', 'Enables verbose logging.');

async function withDatabase<T>(databaseDir: string, options: IDebugCommandOptions, callback: (db: MediaFileDatabase) => Promise<T>): Promise<T> {
  configureLog({ verbose: options.verbose });
  
  const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");
  const { storage: assetStorage } = createStorage(databaseDir, storageOptions);
  const { storage: metadataStorage } = createStorage(options.meta || pathJoin(databaseDir, '.db'));
  
  const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY);
  await database.load();
  
  try {
    return await callback(database);
  } finally {
    await database.close();
  }
}

export const debugCommand = new Command('debug')
  .description('Debug commands for Photosphere database components')
  .addCommand(createSortIndexCommand());

function createSortIndexCommand(): Command {
  return new Command('sort-index')
    .description('Debug sort index functionality')
    .addCommand(createListCommand())
    .addCommand(createVisualizeCommand())
    .addCommand(createAnalyzeCommand())
    .addCommand(createVerifyCommand())
    .addCommand(createStatsCommand());
}

function createListCommand(): Command {
  return new Command('list')
    .description('List all sort indexes in the database')
    .argument('[database-dir]', 'Database directory path', process.cwd())
    .addOption(metaOption)
    .addOption(keyOption)
    .addOption(verboseOption)
    .action(async (databaseDir: string, options: IDebugCommandOptions) => {
      await withDatabase(databaseDir, options, async (db: MediaFileDatabase) => {
        log.info('Scanning for sort indexes...');
        
        const collections = db.getCollectionNames();
        log.info(`Found ${collections.length} collections: ${collections.join(', ')}`);
        
        for (const collectionName of collections) {
          const collection = db.getCollection(collectionName);
          const sortIndexes = await collection.getSortIndexes();
          
          if (sortIndexes.length > 0) {
            log.info(`\nCollection: ${collectionName}`);
            for (const index of sortIndexes) {
              log.info(`  - ${index.field} (${index.direction})`);
              log.verbose(`    File: ${index.indexPath}`);
            }
          } else {
            log.verbose(`Collection ${collectionName}: No sort indexes`);
          }
        }
      });
    });
}

function createVisualizeCommand(): Command {
  return new Command('visualize')
    .description('Visualize B-tree structure of a sort index')
    .argument('[database-dir]', 'Database directory path', process.cwd())
    .requiredOption('-c, --collection <collection>', 'Collection name')
    .requiredOption('-f, --field <field>', 'Field name to visualize')
    .option('-d, --direction <direction>', 'Sort direction (asc|desc)', 'asc')
    .option('--max-depth <depth>', 'Maximum tree depth to display', '3')
    .addOption(metaOption)
    .addOption(keyOption)
    .addOption(verboseOption)
    .action(async (databaseDir: string, options: IDebugCommandOptions & { collection: string; field: string; direction?: string; maxDepth?: string }) => {
      await withDatabase(databaseDir, options, async (db: MediaFileDatabase) => {
        const collection = db.getCollection(options.collection);
        const sortIndex = await collection.getSortIndex(options.field, options.direction);
        
        if (!sortIndex) {
          log.error(`Sort index not found: ${options.collection}.${options.field} (${options.direction})`);
          return;
        }
        
        log.info(`Visualizing sort index: ${options.collection}.${options.field} (${options.direction})`);
        log.info('B-tree structure:');
        
        const visualization = await sortIndex.visualizeTree(parseInt(options.maxDepth));
        console.log(visualization);
      });
    });
}

function createAnalyzeCommand(): Command {
  return new Command('analyze')
    .description('Analyze performance characteristics of a sort index')
    .argument('[database-dir]', 'Database directory path', process.cwd())
    .requiredOption('-c, --collection <collection>', 'Collection name')
    .requiredOption('-f, --field <field>', 'Field name to analyze')
    .option('-d, --direction <direction>', 'Sort direction (asc|desc)', 'asc')
    .addOption(metaOption)
    .addOption(keyOption)
    .addOption(verboseOption)
    .action(async (databaseDir: string, options: IDebugCommandOptions & { collection: string; field: string; direction?: string }) => {
      await withDatabase(databaseDir, options, async (db: MediaFileDatabase) => {
        const collection = db.getCollection(options.collection);
        const sortIndex = await collection.getSortIndex(options.field, options.direction);
        
        if (!sortIndex) {
          log.error(`Sort index not found: ${options.collection}.${options.field} (${options.direction})`);
          return;
        }
        
        log.info(`Analyzing sort index: ${options.collection}.${options.field} (${options.direction})`);
        
        const analysis = await sortIndex.analyzeTreeStructure();
        
        log.info('\nPerformance Analysis:');
        log.info(`  Total records: ${analysis.totalRecords}`);
        log.info(`  Tree height: ${analysis.height}`);
        log.info(`  Total nodes: ${analysis.totalNodes}`);
        log.info(`  Leaf nodes: ${analysis.leafNodes}`);
        log.info(`  Internal nodes: ${analysis.internalNodes}`);
        log.info(`  Average records per leaf: ${analysis.avgRecordsPerLeaf.toFixed(2)}`);
        log.info(`  Fill factor: ${(analysis.fillFactor * 100).toFixed(1)}%`);
        log.info(`  Estimated memory usage: ${(analysis.estimatedMemoryUsage / 1024).toFixed(1)} KB`);
        
        if (options.verbose) {
          log.verbose('\nDetailed Node Information:');
          analysis.nodeDetails.forEach((node: any, index: number) => {
            log.verbose(`  Node ${index}: ${node.isLeaf ? 'Leaf' : 'Internal'}, ${node.recordCount} records`);
          });
        }
      });
    });
}

function createVerifyCommand(): Command {
  return new Command('verify')
    .description('Verify integrity of a sort index')
    .argument('[database-dir]', 'Database directory path', process.cwd())
    .requiredOption('-c, --collection <collection>', 'Collection name')
    .requiredOption('-f, --field <field>', 'Field name to verify')
    .option('-d, --direction <direction>', 'Sort direction (asc|desc)', 'asc')
    .option('--fix', 'Attempt to fix integrity issues by rebuilding')
    .addOption(metaOption)
    .addOption(keyOption)
    .addOption(verboseOption)
    .action(async (databaseDir: string, options: IDebugCommandOptions & { collection: string; field: string; direction?: string; fix?: boolean }) => {
      await withDatabase(databaseDir, options, async (db: MediaFileDatabase) => {
        const collection = db.getCollection(options.collection);
        const sortIndex = await collection.getSortIndex(options.field, options.direction);
        
        if (!sortIndex) {
          log.error(`Sort index not found: ${options.collection}.${options.field} (${options.direction})`);
          return;
        }
        
        log.info(`Verifying sort index: ${options.collection}.${options.field} (${options.direction})`);
        
        try {
          const isValid = await sortIndex.verify();
          
          if (isValid) {
            log.info('✓ Sort index integrity check passed');
          } else {
            log.error('✗ Sort index integrity check failed');
            
            if (options.fix) {
              log.info('Rebuilding sort index...');
              await sortIndex.build();
              log.info('✓ Sort index rebuilt successfully');
            } else {
              log.info('Use --fix flag to rebuild the index');
            }
          }
        } catch (error: any) {
          log.error(`Error verifying sort index: ${error.message}`);
          
          if (options.fix) {
            log.info('Attempting to rebuild sort index...');
            try {
              await sortIndex.build();
              log.info('✓ Sort index rebuilt successfully');
            } catch (rebuildError: any) {
              log.error(`Failed to rebuild sort index: ${rebuildError.message}`);
            }
          }
        }
      });
    });
}

function createStatsCommand(): Command {
  return new Command('stats')
    .description('Show statistics for all sort indexes')
    .argument('[database-dir]', 'Database directory path', process.cwd())
    .option('--collection <collection>', 'Limit to specific collection')
    .addOption(metaOption)
    .addOption(keyOption)
    .addOption(verboseOption)
    .action(async (databaseDir: string, options: IDebugCommandOptions & { collection?: string }) => {
      await withDatabase(databaseDir, options, async (db: MediaFileDatabase) => {
        const collections = options.collection ? [options.collection] : db.getCollectionNames();
        
        log.info('Sort Index Statistics\n');
        
        let totalIndexes = 0;
        let totalRecords = 0;
        let totalMemoryUsage = 0;
        
        for (const collectionName of collections) {
          const collection = db.getCollection(collectionName);
          const sortIndexes = await collection.getSortIndexes();
          
          if (sortIndexes.length === 0) {
            if (options.verbose) {
              log.verbose(`${collectionName}: No sort indexes`);
            }
            continue;
          }
          
          log.info(`Collection: ${collectionName}`);
          
          for (const indexInfo of sortIndexes) {
            const sortIndex = await collection.getSortIndex(indexInfo.field, indexInfo.direction);
            if (!sortIndex) continue;
            
            try {
              const analysis = await sortIndex.analyzeTreeStructure();
              totalIndexes++;
              totalRecords += analysis.totalRecords;
              totalMemoryUsage += analysis.estimatedMemoryUsage;
              
              log.info(`  ${indexInfo.field} (${indexInfo.direction}):`);
              log.info(`    Records: ${analysis.totalRecords}`);
              log.info(`    Height: ${analysis.height}`);
              log.info(`    Fill factor: ${(analysis.fillFactor * 100).toFixed(1)}%`);
              log.info(`    Memory: ${(analysis.estimatedMemoryUsage / 1024).toFixed(1)} KB`);
            } catch (error: any) {
              log.error(`    Error analyzing ${indexInfo.field}: ${error.message}`);
            }
          }
          
          log.info('');
        }
        
        if (totalIndexes > 0) {
          log.info('Summary:');
          log.info(`  Total indexes: ${totalIndexes}`);
          log.info(`  Total records: ${totalRecords}`);
          log.info(`  Total memory usage: ${(totalMemoryUsage / 1024).toFixed(1)} KB`);
        }
      });
    });
}