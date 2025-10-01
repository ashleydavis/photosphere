import { Command, Option } from 'commander';
import { SortIndex, createStorage, loadEncryptionKeys, pathJoin, BsonDatabase } from 'storage';
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

async function withDatabase<T>(databaseDir: string, options: IDebugCommandOptions, callback: (db: BsonDatabase, metadataStorage: any) => Promise<T>): Promise<T> {
  configureLog({ verbose: options.verbose });
  
  const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");
  const { storage: metadataStorage } = createStorage(options.meta || pathJoin(databaseDir, '.db'));
  
  const bsonDatabase = new BsonDatabase({
    storage: metadataStorage,
    maxCachedShards: 100,
  });
  
  return await callback(bsonDatabase, metadataStorage);
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
    .description('List sort index files in metadata directory')
    .argument('[database-dir]', 'Database directory path', process.cwd())
    .addOption(metaOption)
    .addOption(keyOption)
    .addOption(verboseOption)
    .action(async (databaseDir: string, options: IDebugCommandOptions) => {
      await withDatabase(databaseDir, options, async (db: BsonDatabase, metadataStorage: any) => {
        log.info('Scanning for sort index files...');
        
        try {
          const files = await metadataStorage.list('sort_indexes');
          
          if (files.length === 0) {
            log.info('No sort index files found');
            return;
          }
          
          log.info(`Found ${files.length} sort index files:`);
          for (const file of files) {
            log.info(`  - ${file}`);
          }
        } catch (error: any) {
          if (error.message.includes('not found') || error.message.includes('does not exist')) {
            log.info('No sort index directory found');
          } else {
            log.error(`Error listing sort indexes: ${error.message}`);
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
    .requiredOption('-f, --field <field>', 'Field name')
    .option('-d, --direction <direction>', 'Sort direction (asc|desc)', 'asc')
    .addOption(metaOption)
    .addOption(keyOption)
    .addOption(verboseOption)
    .action(async (databaseDir: string, options: IDebugCommandOptions & { collection: string; field: string; direction?: string }) => {
      await withDatabase(databaseDir, options, async (db: BsonDatabase, metadataStorage: any) => {
        try {
          const collection = db.collection(options.collection);
          const sortIndex = new SortIndex({
            storage: metadataStorage,
            baseDirectory: '',
            collectionName: options.collection,
            fieldName: options.field,
            direction: (options.direction || 'asc') as 'asc' | 'desc'
          }, collection);
          
          log.info(`Visualizing sort index: ${options.collection}.${options.field} (${options.direction || 'asc'})`);
          log.info('B-tree structure:');
          
          const visualization = await sortIndex.visualizeTree();
          console.log(visualization);
        } catch (error: any) {
          log.error(`Error visualizing sort index: ${error.message}`);
        }
      });
    });
}

function createAnalyzeCommand(): Command {
  return new Command('analyze')
    .description('Analyze performance characteristics of a sort index')
    .argument('[database-dir]', 'Database directory path', process.cwd())
    .requiredOption('-c, --collection <collection>', 'Collection name')
    .requiredOption('-f, --field <field>', 'Field name')
    .option('-d, --direction <direction>', 'Sort direction (asc|desc)', 'asc')
    .addOption(metaOption)
    .addOption(keyOption)
    .addOption(verboseOption)
    .action(async (databaseDir: string, options: IDebugCommandOptions & { collection: string; field: string; direction?: string }) => {
      await withDatabase(databaseDir, options, async (db: BsonDatabase, metadataStorage: any) => {
        try {
          const collection = db.collection(options.collection);
          const sortIndex = new SortIndex({
            storage: metadataStorage,
            baseDirectory: '',
            collectionName: options.collection,
            fieldName: options.field,
            direction: (options.direction || 'asc') as 'asc' | 'desc'
          }, collection);
          
          log.info(`Analyzing sort index: ${options.collection}.${options.field} (${options.direction || 'asc'})`);
          
          const analysis = await sortIndex.analyzeTreeStructure();
          
          log.info('\nTree Structure Analysis:');
          log.info(`  Total nodes: ${analysis.totalNodes}`);
          log.info(`  Leaf nodes: ${analysis.leafNodes}`);
          log.info(`  Internal nodes: ${analysis.internalNodes}`);
          log.info(`  Min keys per node: ${analysis.minKeysPerNode}`);
          log.info(`  Max keys per node: ${analysis.maxKeysPerNode}`);
          log.info(`  Avg keys per node: ${analysis.avgKeysPerNode.toFixed(2)}`);
          
          if (options.verbose) {
            log.verbose('\nDetailed Node Information:');
            analysis.nodeKeyDistribution.forEach((node: any) => {
              log.verbose(`  Node ${node.nodeId}: ${node.isLeaf ? 'Leaf' : 'Internal'}, ${node.keyCount} keys`);
            });
          }
        } catch (error: any) {
          log.error(`Error analyzing sort index: ${error.message}`);
        }
      });
    });
}

function createVerifyCommand(): Command {
  return new Command('verify')
    .description('Verify integrity of a sort index')
    .argument('[database-dir]', 'Database directory path', process.cwd())
    .requiredOption('-c, --collection <collection>', 'Collection name')
    .requiredOption('-f, --field <field>', 'Field name')
    .option('-d, --direction <direction>', 'Sort direction (asc|desc)', 'asc')
    .option('--fix', 'Attempt to fix integrity issues by rebuilding')
    .addOption(metaOption)
    .addOption(keyOption)
    .addOption(verboseOption)
    .action(async (databaseDir: string, options: IDebugCommandOptions & { collection: string; field: string; direction?: string; fix?: boolean }) => {
      await withDatabase(databaseDir, options, async (db: BsonDatabase, metadataStorage: any) => {
        try {
          const collection = db.collection(options.collection);
          const sortIndex = new SortIndex({
            storage: metadataStorage,
            baseDirectory: '',
            collectionName: options.collection,
            fieldName: options.field,
            direction: (options.direction || 'asc') as 'asc' | 'desc'
          }, collection);
          
          log.info(`Verifying sort index: ${options.collection}.${options.field} (${options.direction || 'asc'})`);
          
          try {
            // Try to get a page to verify the index works
            await sortIndex.getPage();
            log.info('✓ Sort index appears to be working');
          } catch (verifyError: any) {
            log.error('✗ Sort index verification failed');
            
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
      await withDatabase(databaseDir, options, async (db: BsonDatabase, metadataStorage: any) => {
        log.info('Sort Index Statistics\n');
        
        try {
          const baseIndexPath = 'sort_indexes';
          
          if (options.collection) {
            // Show stats for specific collection
            const collectionPath = `${baseIndexPath}/${options.collection}`;
            if (await metadataStorage.dirExists(collectionPath)) {
              const result = await metadataStorage.listDirs(collectionPath, 1000);
              const directories = result.names || [];
              
              log.info(`Collection: ${options.collection}`);
              
              for (const dir of directories) {
                const match = dir.match(/^(.+)_(asc|desc)$/);
                if (match) {
                  const fieldName = match[1];
                  const direction = match[2] as 'asc' | 'desc';
                  
                  try {
                    const collection = db.collection(options.collection);
                    const sortIndex = new SortIndex({
                      storage: metadataStorage,
                      baseDirectory: '',
                      collectionName: options.collection,
                      fieldName,
                      direction
                    }, collection);
                    
                    const analysis = await sortIndex.analyzeTreeStructure();
                    
                    log.info(`  ${fieldName} (${direction}):`);
                    log.info(`    Total nodes: ${analysis.totalNodes}`);
                    log.info(`    Leaf nodes: ${analysis.leafNodes}`);
                    log.info(`    Internal nodes: ${analysis.internalNodes}`);
                    log.info(`    Avg keys per node: ${analysis.avgKeysPerNode.toFixed(2)}`);
                    log.info('');
                  } catch (error: any) {
                    log.error(`    Error analyzing ${fieldName}: ${error.message}`);
                  }
                }
              }
            } else {
              log.info(`No sort indexes found for collection: ${options.collection}`);
            }
          } else {
            // Show stats for all collections
            if (await metadataStorage.dirExists(baseIndexPath)) {
              const result = await metadataStorage.listDirs(baseIndexPath, 1000);
              const collections = result.names || [];
              
              if (collections.length === 0) {
                log.info('No sort indexes found');
                return;
              }
              
              for (const collectionName of collections) {
                log.info(`Collection: ${collectionName}`);
                
                const collectionPath = `${baseIndexPath}/${collectionName}`;
                const indexResult = await metadataStorage.listDirs(collectionPath, 1000);
                const directories = indexResult.names || [];
                
                for (const dir of directories) {
                  const match = dir.match(/^(.+)_(asc|desc)$/);
                  if (match) {
                    log.info(`  - ${match[1]} (${match[2]})`);
                  }
                }
                log.info('');
              }
            } else {
              log.info('No sort index directory found');
            }
          }
        } catch (error: any) {
          log.error(`Error listing sort indexes: ${error.message}`);
        }
      });
    });
}