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
        { command: "psi init", description: "Create database in current directory." },
        { command: "psi init ./photos", description: "Create database in ./photos directory." },
        { command: "psi init ./photos -m ./photos-meta", description: "Create with custom metadata directory." }
    ],
    
    add: [
        { command: "psi add ./photos ~/Pictures", description: "Add all files from ~/Pictures to database." },
        { command: "psi add ./photos image.jpg video.mp4", description: "Add specific files to database." },
        { command: "psi add ./photos ~/Downloads/photos", description: "Add directory recursively." }
    ],
    
    check: [
        { command: "psi check ./photos ~/Pictures", description: "Check which files from ~/Pictures are already in database." },
        { command: "psi check ./photos image.jpg", description: "Check if specific file is already in database." },
        { command: "psi check ./photos ~/Downloads", description: "Check directory to see what's already been added." }
    ],
    
    ui: [
        { command: "psi ui", description: "Start UI for database in current directory." },
        { command: "psi ui ./photos", description: "Start UI for database in ./photos directory." },
        { command: "psi ui ./photos --no-open", description: "Start UI without opening browser automatically." }
    ],
    
    configure: [
        { command: "psi configure", description: "Configure S3 credentials for default profile." },
        { command: "psi configure -p mycloud", description: "Configure S3 credentials for 'mycloud' profile." },
        { command: "psi configure --clear", description: "Clear all S3 configuration files." }
    ],
    
    info: [
        { command: "psi info photo.jpg", description: "Show detailed information about a photo." },
        { command: "psi info photo1.jpg photo2.jpg", description: "Analyze multiple specific files." },
        { command: "psi info ~/Pictures", description: "Analyze all media files in a directory." }
    ],
    
    tools: [
        { command: "psi tools", description: "Check status of all required tools." }
    ],
    
    summary: [
        { command: "psi summary", description: "Show summary for database in current directory." },
        { command: "psi summary ./photos", description: "Show summary for database in ./photos directory." }
    ],
    
    verify: [
        { command: "psi verify", description: "Verify database in current directory." },
        { command: "psi verify ./photos", description: "Verify database in ./photos directory." },
        { command: "psi verify ./photos --full", description: "Force full verification of all files." }
    ],
    
    replicate: [
        { command: "psi replicate ./photos ./backup", description: "Replicate database to backup location." },
        { command: "psi replicate . s3:bucket/photos", description: "Replicate current database to S3." },
        { command: "psi replicate ./photos ./remote -d ./remote-meta", description: "Use custom metadata directory." }
    ],
    
    compare: [
        { command: "psi compare ./photos ./backup", description: "Compare original database with backup." },
        { command: "psi compare . s3:bucket/photos", description: "Compare local database with S3 version." },
        { command: "psi compare ./photos ./mirror -s ./photos-meta", description: "Use custom metadata directories." }
    ],
    
    "bug-report": [
        { command: "psi bug-report", description: "Generate bug report and open in browser." },
        { command: "psi bug-report --no-browser", description: "Generate bug report without opening browser." }
    ],
    
    examples: [
        { command: "psi examples", description: "Show all usage examples categorized by command." }
    ],
    
    "debug merkle-tree": [
        { command: "psi debug merkle-tree", description: "Show merkle tree for current directory." },
        { command: "psi debug merkle-tree ./photos", description: "Show merkle tree for ./photos database." }
    ],
    
    "debug hash-cache": [
        { command: "psi debug hash-cache", description: "Show both local and database hash caches." },
        { command: "psi debug hash-cache -t local", description: "Show only local hash cache information." },
        { command: "psi debug hash-cache ./photos -t database", description: "Show database cache for ./photos." }
    ]
};

//
// Main program examples (shown in the main help)
//
export const MAIN_EXAMPLES: ICommandExample[] = [
    { command: "psi init ./photos", description: "Create a new database in ./photos directory." },
    { command: "psi add ./photos ~/Pictures", description: "Add all media files from ~/Pictures to database." },
    { command: "psi summary ./photos", description: "Show database summary (file count, size, etc.)." },
    { command: "psi verify ./photos", description: "Verify database integrity." },
    { command: "psi replicate ./photos ./backup", description: "Replicate database to backup location." },
    { command: "psi compare ./photos ./backup", description: "Compare two databases for differences." }
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