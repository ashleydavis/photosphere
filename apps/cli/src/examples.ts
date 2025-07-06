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
        { command: "psi init --db ./photos -m ./photos-meta", description: "Creates with custom metadata directory." }
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
    
    ui: [
        { command: "psi ui --db .", description: "Starts the UI for database in current directory." },
        { command: "psi ui --db ./photos", description: "Starts the UI for database in ./photos directory." },
        { command: "psi ui --db ./photos --no-open", description: "Starts the UI without opening browser automatically." }
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
    
    replicate: [
        { command: "psi replicate --db ./photos --dest ./backup", description: "Replicates a database to a backup location." },
        { command: "psi replicate --db . --dest s3:bucket/photos", description: "Replicates the current database to S3." },
        { command: "psi replicate --db ./photos --dest ./remote --dest-meta ./remote-meta", description: "Uses a custom destination metadata directory." }
    ],
    
    compare: [
        { command: "psi compare --db ./photos --dest ./backup", description: "Compares an original database with a backup." },
        { command: "psi compare --db . --dest s3:bucket/photos", description: "Compares a local database with an S3 replica." },
        { command: "psi compare --db ./photos --dest ./mirror -s ./photos-meta", description: "Uses custom metadata directories." }
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
        { command: "psi export --db ./photos abc123 ./exported-photo.jpg", description: "Exports original asset with ID abc123 to a specific file." },
        { command: "psi export --db ./photos def456 ./exports/", description: "Exports original asset with ID def456 to a directory (keeps original name)." },
        { command: "psi export --db . xyz789 ~/Downloads/my-photo.jpg --type display", description: "Exports display version of asset xyz789." },
        { command: "psi export --db ./photos abc123 ./thumbs/ --type thumb", description: "Exports thumbnail version to directory." }
    ],
    
    "debug merkle-tree": [
        { command: "psi debug merkle-tree --db .", description: "Shows the merkle tree for current directory." },
        { command: "psi debug merkle-tree --db ./photos", description: "Shows the merkle tree for ./photos database." }
    ],
    
    "debug hash-cache": [
        { command: "psi debug hash-cache --db .", description: "Shows both the local and database hash caches." },
        { command: "psi debug hash-cache --db . -t local", description: "Shows only the local hash cache information." },
        { command: "psi debug hash-cache --db ./photos -t database", description: "Shows the database cache for ./photos." }
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