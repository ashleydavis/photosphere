export interface ICommandExample {
    command: string;
    description: string;
}

export interface ICommandExamples {
    [commandName: string]: ICommandExample[];
}

//
// Centralized examples for all CLI commands
//
export const COMMAND_EXAMPLES: ICommandExamples = {
    init: [
        { command: "psi init --db .", description: "Creates a database in current directory." },
        { command: "psi init --db ./photos", description: "Creates a database in ./photos directory." },
    ],
    
    add: [
        { command: "psi add --db ./photos ~/Pictures", description: "Adds all files from ~/Pictures to the database." },
        { command: "psi add --db ./photos image.jpg video.mp4", description: "Adds specific files to the database." },
        { command: "psi add --db ./photos ~/Downloads/photos", description: "Adds a directory recursively." }
    ],
    
    check: [
        { command: "psi check --db ./photos ~/Pictures", description: "Checks which files from ~/Pictures are already in database." },
        { command: "psi check --db ./photos image.jpg", description: "Checks if the specific file is already in database." },
        { command: "psi check --db ./photos ~/Downloads", description: "Checks the directory to see what's already been added." }
    ],
    
    config: [
        { command: "psi config", description: "Interactive wizard to configure S3 credentials and Google API key." },
        { command: "psi config --clear", description: "Clears all configuration files." }
    ],
    
    info: [
        { command: "psi info photo.jpg", description: "Shows detailed information about a photo." },
        { command: "psi info photo1.jpg photo2.jpg", description: "Analyzes multiple specific files." },
        { command: "psi info ~/Pictures", description: "Analyzes all media files in a directory." }
    ],
    
    tools: [
        { command: "psi tools", description: "Checks the status of all required media processing tools." }
    ],
    
    summary: [
        { command: "psi summary --db .", description: "Shows a summary for the database in current directory." },
        { command: "psi summary --db ./photos", description: "Shows summary for the database in the ./photos directory." }
    ],
    
    verify: [
        { command: "psi verify --db .", description: "Verifies a database in the current directory." },
        { command: "psi verify --db ./photos", description: "Verifies a database in the ./photos directory." },
        { command: "psi verify --db ./photos --full", description: "Forces full verification of all files." }
    ],
    
    repair: [
        { command: "psi repair --db ./photos --source ./backup", description: "Repairs corrupted files from a backup database." },
        { command: "psi repair --db . --source ./backup --full", description: "Forces full repair verification of all files." },
    ],
    
    replicate: [
        { command: "psi replicate --db ./photos --dest ./backup", description: "Replicates a database to a backup location." },
        { command: "psi replicate --db . --dest s3:bucket/photos", description: "Replicates the current database to S3." },
    ],
    
    compare: [
        { command: "psi compare --db ./photos --dest ./backup", description: "Compares an original database with a backup." },
        { command: "psi compare --db . --dest s3:bucket/photos", description: "Compares a local database with an S3 replica." },
        { command: "psi compare --db ./photos --dest ./backup --full", description: "Shows all differences without truncation." },
        { command: "psi compare --db ./photos --dest ./backup --max 20", description: "Shows up to 20 items in each category." },
    ],
    
    "bug": [
        { command: "psi bug", description: "Generates a bug report and opens it in the browser." },
        { command: "psi bug --no-browser", description: "Generates a bug report without opening a browser." }
    ],
    
    examples: [
        { command: "psi examples", description: "Shows all usage examples categorized by command." }
    ],
    
    version: [
        { command: "psi version", description: "Shows version information for psi and its dependencies." }
    ],
    
    export: [
        { command: "psi export --db ./photos a1b2c3d4-e5f6-7890-abcd-ef1234567890 ./exported-photo.jpg", description: "Exports original asset with ID to a specific file." },
        { command: "psi export --db ./photos f1e2d3c4-b5a6-7890-cdef-ab1234567890 ./exports/", description: "Exports original asset to a directory (keeps original name)." },
        { command: "psi export --db . 12345678-9abc-def0-1234-567890abcdef ~/Downloads/my-photo.jpg --type display", description: "Exports display version of asset." },
        { command: "psi export --db ./photos a1b2c3d4-e5f6-7890-abcd-ef1234567890 ./thumbs/ --type thumb", description: "Exports thumbnail version to directory." }
    ],
    
    "find-orphans": [
        { command: "psi find-orphans --db .", description: "Finds orphaned files in the current directory database." },
        { command: "psi find-orphans --db ./photos", description: "Finds orphaned files in the ./photos database." },
    ],
    
    "remove-orphans": [
        { command: "psi remove-orphans --db .", description: "Removes orphaned files from the current directory database." },
        { command: "psi remove-orphans --db ./photos", description: "Removes orphaned files from the ./photos database." },
        { command: "psi remove-orphans --db ./photos --yes", description: "Removes orphaned files without confirmation prompt." },
    ],
    
    list: [
        { command: "psi list --db .", description: "Lists all files in the current directory database." },
        { command: "psi list --db ./photos", description: "Lists all files in the ./photos database." },
        { command: "psi list --db ./photos --page-size 10", description: "Lists files with 10 files per page." }
    ],
    
    upgrade: [
        { command: "psi upgrade --db .", description: "Upgrades the database in current directory to latest version." },
        { command: "psi upgrade --db ./photos", description: "Upgrades the database in ./photos directory." },
    ],
    
    remove: [
        { command: "psi remove --db ./photos a1b2c3d4-e5f6-7890-abcd-ef1234567890", description: "Removes asset with ID from the database." },
        { command: "psi remove --db . f1e2d3c4-b5a6-7890-cdef-ab1234567890", description: "Removes asset from current directory database." },
    ],
    
    hash: [
        { command: "psi hash photo.jpg", description: "Computes hash of a local file using the same algorithm as the database." },
        { command: "psi hash s3://my-bucket/photo.jpg", description: "Computes hash of file stored in S3." },
        { command: "psi hash fs:/path/to/photo.jpg", description: "Computes hash with explicit filesystem prefix." },
        { command: "psi hash --key ./key encrypted:photo.jpg", description: "Computes hash of an encrypted file." }
    ],
    
    sync: [
        { command: "psi sync --db ./photos --dest ./backup", description: "Synchronizes changes between two databases." },
        { command: "psi sync --db . --dest s3:bucket/photos", description: "Synchronizes local database with an S3 replica." },
    ]
};

//
// Main program examples (shown in the main help)
//
export const MAIN_EXAMPLES: ICommandExample[] = [
    { command: "psi init --db ./photos", description: "Creates a new database in the ./photos directory." },
    { command: "psi add --db ./photos ~/Pictures", description: "Adds all media files from ~/Pictures to the database." },
    { command: "psi summary --db ./photos", description: "Shows the database summary (file count, size, etc.)." },
    { command: "psi verify --db ./photos", description: "Verifies the database integrity." },
    { command: "psi replicate --db ./photos --dest ./backup", description: "Replicates one database to a backup location." },
    { command: "psi sync --db ./photos --dest ./backup", description: "Synchronizes changes between two databases." },
    { command: "psi compare --db ./photos --dest ./backup", description: "Compares two databases for differences." }
];

//
// Helper function to format examples for help text
//
export function formatExamplesForHelp(examples: ICommandExample[]): string {
    return examples
        .map(example => `  ${example.command.padEnd(32)} ${example.description}`)
        .join('\n');
}

//
// Helper function to get examples help text for a command
//
export function getCommandExamplesHelp(commandName: string): string {
    const examples = COMMAND_EXAMPLES[commandName];
    if (!examples || examples.length === 0) {
        return '';
    }
    
    return `\nExamples:\n${formatExamplesForHelp(examples)}`;
}