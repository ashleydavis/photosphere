import { program } from 'commander';
import { showCommand } from './cmd/show';
import { rootHashCommand } from './cmd/root-hash';
import pc from "picocolors";

async function main() {
    program
        .name("mk")
        .description(`A command-line tool for inspecting and visualizing merkle trees.`)
        .version('0.0.1')
        .addHelpText('after', `

Examples:
  ${pc.bold("mk show ./path/to/tree.dat")}                 Show merkle tree visualization
  ${pc.bold("mk root-hash ./path/to/tree.dat")}           Print the root hash

Resources:
  📖 Merkle Tree Package: packages/merkle-tree
  📚 Main Project: https://github.com/ashleydavis/photosphere`)
        .exitOverride();  // Prevent commander from calling process.exit

    program
        .command("show")
        .description("Visualize the merkle tree structure from a saved tree file")
        .argument("<tree-file>", "Path to the merkle tree file")
        .option("-v, --verbose", "Enable verbose logging", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("mk show ./my-database/.db/tree.dat")}
  ${pc.bold("mk show ./my-database/.db/custom.dat")}
  ${pc.bold("mk show s3://my-bucket/database/.db/tree.dat")}`)
        .action(showCommand);

    program
        .command("root-hash")
        .description("Print the root hash of the merkle tree")
        .argument("<tree-file>", "Path to the merkle tree file")
        .option("-v, --verbose", "Enable verbose logging", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("mk root-hash ./my-database/.db/tree.dat")}
  ${pc.bold("mk root-hash s3://my-bucket/database/.db/tree.dat")}`)
        .action(rootHashCommand);

    // Parse the command line arguments
    try {
        await program.parseAsync(process.argv);
    } catch (err: any) {
        // Commander throws an error when no command is provided
        // Check if this is just a help display situation
        if (err.code === 'commander.help' 
            || err.code === 'commander.helpDisplayed') {
            process.exit(0);
        }
        
        if (err.code === 'commander.missingArgument' 
            || err.code === 'commander.unknownOption'
            || err.code === 'commander.unknownCommand' 
            || err.code === 'commander.excessArguments') {
            process.exit(1);
        }

        // If no command was provided and we're showing help
        if (process.argv.length <= 2) {
            process.exit(0);
        }

        throw err;
    }
}

//
// Handles errors in a consistent way.
//
function handleError(error: any) {
    console.error(pc.red('An error occurred:'));
    if (error.message) {
        console.error(pc.red(error.message));
    }
    if (error.stack) {
        console.error(pc.red(error.stack));
    } else {
        console.error(pc.red(error.toString()));
    }
    process.exit(1);
}

// Handle unhandled errors
process.on('uncaughtException', (error) => {
    handleError(error);
});

// Handle unhandled promise rejections
process.on('unhandledRejection', (reason, promise) => {
    handleError(reason);
});

main()
    .catch((error) => {
        handleError(error);
    });

