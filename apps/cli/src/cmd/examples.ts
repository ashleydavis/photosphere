import pc from "picocolors";
import { COMMAND_EXAMPLES, formatExamplesForHelp } from "../examples";
import { log } from "utils";

//
// Command to display all examples categorized by command
//
export async function examplesCommand(): Promise<void> {
    log.info(pc.bold(pc.blue('📖 Photosphere CLI Examples')));
    log.info('');
    log.info('Below are usage examples for all available commands:');
    log.info('');

    // Group commands by category for better organization
    const categories = {
        'Database Management': ['init', 'add', 'check', 'summary', 'verify', 'find-orphans', 'remove-orphans'],
        'Backup and syncrhonization': ['replicate', 'compare'],
        'Configuration': ['config', 'tools'],
        'File Analysis': ['info'],
        'Help and Support': ['examples', 'bug'],
    };

    for (const [categoryName, commands] of Object.entries(categories)) {
        log.info(pc.bold(pc.cyan(`${categoryName}:`)));
        log.info('');

        for (const commandName of commands) {
            const examples = COMMAND_EXAMPLES[commandName];
            if (examples && examples.length > 0) {
                log.info(pc.bold(`  ${commandName}:`));
                const formattedExamples = formatExamplesForHelp(examples);
                // Indent each line by 4 spaces
                const indentedExamples = formattedExamples
                    .split('\n')
                    .map(line => `  ${line}`)
                    .join('\n');
                log.info(indentedExamples);
                log.info('');
            }
        }
    }

    log.info('💡 Tip: Use "psi <command> --help" to see detailed help for any specific command.');
    log.info('');
}