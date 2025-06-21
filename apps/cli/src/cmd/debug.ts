import { Command } from 'commander';
import { merkleTreeCommand } from './merkle-tree';
import { hashCacheCommand } from './hash-cache';
import pc from "picocolors";

//
// Command to group debug utilities
//
export function createDebugCommand(): Command {
    const debugCommand = new Command('debug')
        .description('Debug utilities for inspecting the media file database internals');

    // Add merkle-tree subcommand
    debugCommand
        .command('merkle-tree')
        .description('Visualize the merkle tree structure of the media file database')
        .argument('[database-dir]', 'The directory that contains the media file database. Defaults to the current directory.')
        .option('-m, --meta <db-metadata-dir>', 'The directory in which to store asset database metadata. (default: "<current-dir>/.db")')
        .option('-k, --key <keyfile>', 'Path to the private key file for encryption.')
        .option('-v, --verbose', 'Enables verbose logging.', false)
        .option('-y, --yes', 'Non-interactive mode. Use command line arguments and defaults.', false)
        .addHelpText('after', `
Examples:
  psi debug merkle-tree                Show merkle tree for current directory.
  psi debug merkle-tree ./photos       Show merkle tree for ./photos database.`)
        .action(merkleTreeCommand);

    // Add hash-cache subcommand
    debugCommand
        .command('hash-cache')
        .description('Display information about the local and database hash caches')
        .argument('[database-dir]', 'The directory that contains the media file database. Defaults to the current directory.')
        .option('-m, --meta <db-metadata-dir>', 'The directory in which to store asset database metadata. (default: "<current-dir>/.db")')
        .option('-k, --key <keyfile>', 'Path to the private key file for encryption.')
        .option('-v, --verbose', 'Enables verbose logging.', false)
        .option('-y, --yes', 'Non-interactive mode. Use command line arguments and defaults.', false)
        .option('-t, --type <type>', 'Cache type to display: \'local\', \'database\', or \'both\' (default: \'both\')')
        .addHelpText('after', `
Examples:
  psi debug hash-cache                 Show both local and database hash caches.
  psi debug hash-cache -t local        Show only local hash cache information.
  psi debug hash-cache ./photos -t database  Show database cache for ./photos.`)
        .action(hashCacheCommand);

    return debugCommand;
}