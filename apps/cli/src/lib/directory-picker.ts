import { select, text, confirm, isCancel, outro } from './clack/prompts';
import * as fs from 'fs/promises';
import { existsSync } from 'fs';
import { join, resolve } from 'path';
import pc from 'picocolors';
import { exit, pathExists } from 'node-utils';

//
// Checks if a directory is a valid Photosphere media database
//
async function isMediaDatabase(dirPath: string): Promise<boolean> {
    try {
        const dbDir = join(dirPath, '.db');
        if (!await pathExists(dbDir)) {
            return false;
        }

        const treePath = join(dbDir, 'tree.dat');
        return await pathExists(treePath);
    } catch (error) {
        return false;
    }
}


//
// Checks if a directory is empty or doesn't exist (suitable for init)
//
async function isEmptyOrNonExistent(dirPath: string): Promise<boolean> {
    if (!await pathExists(dirPath)) {
        return true;
    }
    
    try {
        const contents = await fs.readdir(dirPath);
        return contents.length === 0;
    } catch (error) {
        return false;
    }
}

//
// Prompts user to select a directory with simplified options
//
export async function pickDirectory(
    message: string,
    currentDir: string = process.cwd(),
    validator?: (path: string) => Promise<boolean | string>
): Promise<string | null> {
    const currentPath = resolve(currentDir);
    
    // Check if current directory is valid
    let canUseCurrentDir = true;
    let currentDirMessage = '';
    if (validator) {
        const result = await validator(currentPath);
        if (result !== true) {
            canUseCurrentDir = false;
            currentDirMessage = typeof result === 'string' ? result : 'Invalid directory';
        }
    }
    
    const options = [];
    
    // Option 1: Use current directory (only if empty/valid)
    if (canUseCurrentDir) {
        options.push({ 
            label: `📁 Use current directory`, 
            value: 'current' 
        });
    }
    
    // Option 2: Create subdirectory
    options.push({ 
        label: '📂 Create subdirectory in current location', 
        value: 'subdirectory' 
    });
    
    // Option 3: Enter full path
    options.push({ 
        label: '📝 Enter full path', 
        value: 'fullpath' 
    });
    
    // Cancel option
    options.push({ 
        label: '❌ Cancel', 
        value: 'cancel' 
    });
    
    // Note about current directory will be shown in the prompt message if needed
    
    const choice = await select({
        message,
        options
    });

    if (isCancel(choice)) {
        return null;
    }

    switch (choice) {
        case 'current':
            return '.';
            
        case 'subdirectory':
            const subdirName = await text({
                message: 'Enter name for subdirectory:',
                placeholder: 'my-photos',
                validate: (value) => {
                    if (!value || value.trim().length === 0) {
                        return 'Directory name is required';
                    }
                    // Check for invalid characters
                    if (/[\/\\:*?"<>|]/.test(value)) {
                        return 'Directory name contains invalid characters';
                    }
                    // Check if directory already exists
                    const newPath = join(currentPath, value);
                    if (existsSync(newPath)) {
                        return 'Directory already exists';
                    }
                    return undefined;
                },
            });
            
            if (isCancel(subdirName)) {
                return null;
            }
            
            const subdirPath = join(currentPath, String(subdirName));
            const relativePath = `./${String(subdirName)}`;
            try {
                await fs.mkdir(subdirPath, { recursive: true });
                
                // Validate the new directory
                if (validator) {
                    const result = await validator(subdirPath);
                    if (result !== true) {
                        outro(pc.red(typeof result === 'string' ? result : 'Invalid directory'));
                        return null;
                    }
                }
                
                return relativePath;
            } catch (error) {
                outro(pc.red(`Failed to create directory: ${error instanceof Error ? error.message : 'Unknown error'}`));
                return null;
            }
            
        case 'fullpath':
            const fullPath = await text({
                message: 'Enter full directory path:',
                placeholder: '/path/to/directory',
                validate: (value) => {
                    if (!value || value.trim().length === 0) {
                        return 'Path is required';
                    }
                    return undefined;
                },
            });
            
            if (isCancel(fullPath)) {
                return null;
            }
            
            const resolvedPath = resolve(String(fullPath));
            
            // Create directory if it doesn't exist
            if (!await pathExists(resolvedPath)) {
                try {
                    await fs.mkdir(resolvedPath, { recursive: true });
                } catch (error) {
                    outro(pc.red(`Failed to create directory: ${error instanceof Error ? error.message : 'Unknown error'}`));
                    return null;
                }
            }
            
            // Validate the directory
            if (validator) {
                const result = await validator(resolvedPath);
                if (result !== true) {
                    outro(pc.red(typeof result === 'string' ? result : 'Invalid directory'));
                    return null;
                }
            }
            
            return resolvedPath;
            
        case 'cancel':
            return null;
            
        default:
            return null;
    }
}

//
// Validates directory for init command (empty or non-existent)
//
async function validateInitDirectory(path: string): Promise<boolean | string> {
    if (await isEmptyOrNonExistent(path)) {
        return true;
    }
    
    return "can't use this directory because it's not empty";
}


//
// Validates directory for other commands (existing media database)
//
async function validateExistingDatabase(path: string): Promise<boolean | string> {
    if (!await pathExists(path)) {
        return 'Directory does not exist';
    }
    
    if (await isMediaDatabase(path)) {
        return true;
    }
    
    return 'Directory is not a valid Photosphere media database';
}


//
// Auto-detects and prompts for directory based on command type
//
export async function getDirectoryForCommand(
    commandType: 'init' | 'existing',
    nonInteractive: boolean,
    cwd: string
): Promise<string> {

    // Check if current directory is suitable
    const currentDir = cwd;
    
    if (commandType === 'init') {
        if (await validateInitDirectory(currentDir) === true) {
            return currentDir;
        } else {
            // Current directory is not empty, skip asking and go straight to picker in interactive mode
            if (nonInteractive) {
                console.error(pc.red('Current directory is not empty. Please specify an empty directory or use a different location.'));
                await exit(1);
            }
        }
    } else {
        if (await isMediaDatabase(currentDir)) {
            return currentDir;
        }
    }
    
    // If non-interactive and we get here, we can't proceed
    if (nonInteractive) {
        if (commandType === 'init') {
            console.error(pc.red('Current directory is not empty. Please specify an empty directory or use a different location.'));
        } else {
            console.error(pc.red('Current directory is not a media database. Please specify a valid media database directory.'));
        }
        await exit(1);
    }
    
    // Interactive mode: show directory picker
    const message = commandType === 'init' 
        ? 'Select an empty directory for new media database:'
        : 'Select an existing media database directory:';
        
    const validator = commandType === 'init' 
        ? validateInitDirectory
        : validateExistingDatabase;
    
    const selectedDir = await pickDirectory(message, currentDir, validator);
    
    if (!selectedDir) {
        outro(pc.red('No directory selected'));
        await exit(1);
    }
    
    return selectedDir!;
}