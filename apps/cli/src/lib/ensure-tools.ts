import { ensureToolsAvailable } from 'tools';
import pc from "picocolors";
import { exit } from 'node-utils';

//
// Ensures tools are available for commands that need media processing.
// Shows user-friendly error and exits if tools are missing.
//
export async function ensureMediaProcessingTools(): Promise<void> {
    const toolsAvailable = await ensureToolsAvailable({ 
        promptForInstall: true, 
        silent: false 
    });
    
    if (!toolsAvailable) {
        console.error(pc.red('❌ Required media processing tools are not available.'));
        console.log();
        console.log('To install the missing tools, run:');
        console.log(pc.cyan('  psi tools'));
        console.log();
        console.log('Or install them manually - run this for instructions:');
        console.log(pc.cyan('  psi tools list'));
        exit(1);
    }
}