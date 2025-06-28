import { ensureToolsAvailable, verifyTools } from 'tools';
import pc from "picocolors";
import { exit } from 'node-utils';
import { confirm, isCancel } from "@clack/prompts";
import { showInstallationInstructions } from "./installation-instructions";

//
// Ensures tools are available for commands that need media processing.
// Shows user-friendly error and exits if tools are missing.
//
export async function ensureMediaProcessingTools(nonInteractive: boolean): Promise<void> {
    const toolsStatus = await verifyTools();
    
    if (toolsStatus.allAvailable) {
        return; // All tools are available, continue
    }
    
    // Tools are missing, show error and ask for installation instructions
    console.error(pc.red('❌ Required media processing tools are not available.'));
    console.log();
    
    const missingTools = toolsStatus.missingTools;
    console.log(pc.yellow(`Missing tools: ${missingTools.join(', ')}`));
    console.log();
    
    // Ask if user wants to see installation instructions (or show them automatically in non-interactive mode)
    let showInstructions = true;
    if (!nonInteractive) {
        const userChoice = await confirm({
            message: 'Would you like to see installation instructions?',
            initialValue: true
        });
        
        if (isCancel(userChoice)) {
            console.log();
            console.log(pc.blue('Please install the missing tools and try again.'));
            console.log(pc.blue('You can also run: ') + pc.cyan('psi tools') + pc.blue(' to see installation instructions'));
            await exit(1);
        }
        showInstructions = userChoice as boolean;
    }
    
    if (!showInstructions) {
        console.log();
        console.log(pc.blue('Please install the missing tools and try again.'));
        console.log(pc.blue('You can also run: ') + pc.cyan('psi tools') + pc.blue(' to see installation instructions'));
        await exit(1);
    }
    
    showInstallationInstructions(missingTools);
    
    await exit(1);
}