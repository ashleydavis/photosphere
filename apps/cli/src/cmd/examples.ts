import pc from "picocolors";
import { COMMAND_EXAMPLES, formatExamplesForHelp } from "../examples";

//
// Command to display all examples categorized by command
//
export async function examplesCommand(): Promise<void> {
    console.log(pc.bold(pc.blue('📖 Photosphere CLI Examples')));
    console.log();
    console.log('Below are usage examples for all available commands:');
    console.log();

    // Group commands by category for better organization
    const categories = {
        'Database Management': ['init', 'add', 'check', 'summary', 'verify', 'find-orphans', 'remove-orphans'],
        'Backup and syncrhonization': ['replicate', 'compare'],
        'Configuration': ['config', 'tools'],
        'File Analysis': ['info'],
        'Help and Support': ['examples', 'bug'],
    };

    for (const [categoryName, commands] of Object.entries(categories)) {
        console.log(pc.bold(pc.cyan(`${categoryName}:`)));
        console.log();

        for (const commandName of commands) {
            const examples = COMMAND_EXAMPLES[commandName];
            if (examples && examples.length > 0) {
                console.log(pc.bold(`  ${commandName}:`));
                const formattedExamples = formatExamplesForHelp(examples);
                // Indent each line by 4 spaces
                const indentedExamples = formattedExamples
                    .split('\n')
                    .map(line => `  ${line}`)
                    .join('\n');
                console.log(indentedExamples);
                console.log();
            }
        }
    }

    console.log('💡 Tip: Use "psi <command> --help" to see detailed help for any specific command.');
    console.log();
}