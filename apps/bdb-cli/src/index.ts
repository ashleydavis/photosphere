import { program } from 'commander';
import { collectionsCommand } from './cmd/collections';
import { collectionCommand } from './cmd/collection';
import { shardsCommand } from './cmd/shards';
import { shardCommand } from './cmd/shard';
import { recordCommand } from './cmd/record';
import { editCommand } from './cmd/edit';
import { sortIndexesCommand } from './cmd/sort-indexes';
import { sortIndexCommand } from './cmd/sort-index';
import { sortPageCommand } from './cmd/sort-page';
import pc from "picocolors";

async function main() {
    program
        .name("bdb")
        .description(`A command-line tool for inspecting and managing BSON databases.`)
        .version('0.0.1')
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb colls <db-path>")}                                List all collections
  ${pc.bold("bdb shards <db-path> <collection>")}                 List shards in a collection
  ${pc.bold("bdb shard <db-path> <collection> <shard-id>")}       Show shard contents
  ${pc.bold("bdb record <db-path> <collection> <record-id>")}     Show a specific record
  ${pc.bold("bdb edit <db-path> <collection> <record-id> <field> <type> <value>")}  Edit a field in a record
  ${pc.bold("bdb sort-indexes <db-path> <collection>")}           List sort indexes

Resources:
  📖 BDB Package: packages/bdb
  📚 Main Project: https://github.com/ashleydavis/photosphere`)
        .exitOverride();  // Prevent commander from calling process.exit

    program
        .command("collections")
        .alias("colls")
        .description("Lists all collections in the BSON database")
        .argument("<db-path>", "Path to the database directory")
        .option("-v, --verbose", "Enable verbose logging", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb collections ./my-database")}
  ${pc.bold("bdb colls s3://my-bucket/database")}`)
        .action(collectionsCommand);

    program
        .command("collection")
        .alias("col")
        .description("Show details about a specific collection")
        .argument("<db-path>", "Path to the database directory")
        .argument("<collection-name>", "Name of the collection")
        .option("-v, --verbose", "Enable verbose logging", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb collection ./my-database metadata")}
  ${pc.bold("bdb col s3://my-bucket/database users")}`)
        .action(collectionCommand);

    program
        .command("shards")
        .description("Lists all shards in a collection")
        .argument("<db-path>", "Path to the database directory")
        .argument("<collection-name>", "Name of the collection")
        .option("-v, --verbose", "Enable verbose logging", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb shards ./my-database metadata")}
  ${pc.bold("bdb shards s3://my-bucket/database users")}`)
        .action(shardsCommand);

    program
        .command("shard")
        .description("Deserializes and displays the contents of a specific shard")
        .argument("<db-path>", "Path to the database directory")
        .argument("<collection-name>", "Name of the collection")
        .argument("<shard-id>", "ID of the shard to display")
        .option("-v, --verbose", "Enable verbose logging", false)
        .option("--all", "Display all object fields (no truncation)", false)
        .option("--records", "Only show record IDs, not full record data", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb shard ./my-database metadata 5")}
  ${pc.bold("bdb shard ./my-database metadata 5 --records")}
  ${pc.bold("bdb shard ./my-database users 10 --all")}`)
        .action(shardCommand);

    program
        .command("record")
        .description("Deserializes and displays a specific record from a collection")
        .argument("<db-path>", "Path to the database directory")
        .argument("<collection-name>", "Name of the collection")
        .argument("<record-id>", "ID of the record to display")
        .option("-v, --verbose", "Enable verbose logging", false)
        .option("--all", "Display all object fields (no truncation)", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb record ./my-database metadata abc-123-def")}
  ${pc.bold("bdb record ./my-database users user-456 --all")}`)
        .action(recordCommand);

    program
        .command("edit")
        .description("Edits a field in a record from a collection")
        .argument("<db-path>", "Path to the database directory")
        .argument("<collection-name>", "Name of the collection")
        .argument("<record-id>", "ID of the record to edit")
        .argument("<field-name>", "Name of the field to edit (can be nested, e.g., 'user.name')")
        .argument("<field-type>", "Type of the field: number, string, date, boolean, string-array, or json")
        .argument("<field-value>", "Value to set for the field")
        .option("-v, --verbose", "Enable verbose logging", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb edit ./my-database metadata abc-123-def name string \"John Doe\"")}
  ${pc.bold("bdb edit ./my-database users user-456 age number 30")}
  ${pc.bold("bdb edit ./my-database users user-456 user.name string \"Jane Smith\"")}
  ${pc.bold("bdb edit ./my-database metadata abc-123 tags string-array \"tag1,tag2,tag3\"")}
  ${pc.bold("bdb edit ./my-database metadata abc-123 config json '{\"key\":\"value\"}'")}`)
        .action(editCommand);

    program
        .command("sort-indexes")
        .description("Lists all sort indexes for a collection")
        .argument("<db-path>", "Path to the database directory")
        .argument("<collection-name>", "Name of the collection")
        .option("-v, --verbose", "Enable verbose logging", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb sort-indexes ./my-database metadata")}
  ${pc.bold("bdb sort-indexes s3://my-bucket/database users")}`)
        .action(sortIndexesCommand);

    program
        .command("sort-index")
        .alias("sort-idx")
        .description("Visualizes the structure of a specific sort index")
        .argument("<db-path>", "Path to the database directory")
        .argument("<collection-name>", "Name of the collection")
        .argument("<field-name>", "Name of the field for the sort index")
        .argument("<direction>", "Sort direction: 'asc' or 'desc'")
        .option("-v, --verbose", "Enable verbose logging", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb sort-index ./my-database metadata photoTakenAt desc")}
  ${pc.bold("bdb sort-idx ./my-database users createdAt asc")}`)
        .action(sortIndexCommand);

    program
        .command("sort-page")
        .alias("sort-pg")
        .description("Displays a specific page from a sort index")
        .argument("<db-path>", "Path to the database directory")
        .argument("<collection-name>", "Name of the collection")
        .argument("<field-name>", "Name of the field for the sort index")
        .argument("<direction>", "Sort direction: 'asc' or 'desc'")
        .argument("<page-id>", "ID of the page to display")
        .option("-v, --verbose", "Enable verbose logging", false)
        .addHelpText('after', `

Examples:
  ${pc.bold("bdb sort-page ./my-database metadata photoTakenAt desc page-1")}
  ${pc.bold("bdb sort-pg ./my-database users createdAt asc page-5")}`)
        .action(sortPageCommand);

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


