import { select, text, confirm, isCancel, outro } from '@clack/prompts';
import { existsSync, statSync, readdirSync, mkdirSync } from 'fs';
import { join, resolve, dirname } from 'path';
import pc from 'picocolors';
import { exit } from 'node-utils';
import { MediaFileDatabase } from "api";
import { createStorage } from "storage";

//
// Checks if a directory is a valid Photosphere media database
//
export async function isMediaDatabase(dirPath: string): Promise<boolean> {
    try {
        const dbDir = join(dirPath, '.db');
        if (!existsSync(dbDir)) {
            return false;
        }

        const treePath = join(dbDir, 'tree.dat');
        return existsSync(treePath);
    } catch (error) {
        return false;
    }
}

//
// Checks if a directory is empty or doesn't exist (suitable for init)
//
export function isEmptyOrNonExistent(dirPath: string): boolean {
    if (!existsSync(dirPath)) {
        return true;
    }
    
    try {
        const contents = readdirSync(dirPath);
        return contents.length === 0;
    } catch (error) {
        return false;
    }
}

//
// Prompts user to select a directory with a simple file browser
//
export async function pickDirectory(
    message: string,
    currentDir: string = process.cwd(),
    validator?: (path: string) => boolean | string | Promise<boolean | string>
): Promise<string | null> {
    let currentPath = resolve(currentDir);
    
    while (true) {
        const items = getDirectoryItems(currentPath);
        
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
        
        // Add "Use this directory" option, potentially disabled
        if (canUseCurrentDir) {
            options.push({ label: '📁 Use this directory', value: 'select' });
        } else {
            // Use strikethrough and explain why it can't be used
            options.push({ 
                label: `📁 ${pc.strikethrough('Use this directory')} (${currentDirMessage})`, 
                value: 'select-disabled',
                hint: 'Cannot use this directory'
            });
        }
        
        options.push(
            { label: '⬆️  Parent directory', value: 'parent' },
            { label: '➕ Create new directory here', value: 'create' },
            { label: '📝 Enter path manually', value: 'manual' },
            { label: '❌ Cancel', value: 'cancel' },
            ...items.map(item => ({
                label: `${item.isDir ? '📁' : '📄'} ${item.name}`,
                value: item.path,
                hint: item.isDir ? 'directory' : 'file'
            }))
        );
        
        const choice = await select({
            message: `${message}\nCurrent: ${currentPath}`,
            options
        });

        if (isCancel(choice)) {
            return null;
        }

        switch (choice) {
            case 'select':
                // This should only be reachable if canUseCurrentDir is true
                return currentPath;
                
            case 'select-disabled':
                // User clicked on disabled option, show message and continue
                outro(pc.yellow(`Cannot use this directory: ${currentDirMessage}`));
                continue;
                
            case 'parent':
                currentPath = dirname(currentPath);
                break;
                
            case 'create':
                const newDirName = await text({
                    message: `Enter name for new directory:\nWill be created at: ${currentPath}/[name]`,
                    placeholder: 'my-photos',
                    validate: (value) => {
                        if (!value || value.trim().length === 0) {
                            return 'Directory name is required';
                        }
                        // Check for invalid characters
                        if (!/^[a-zA-Z0-9._-]+$/.test(value)) {
                            return 'Directory name can only contain letters, numbers, dots, hyphens, and underscores';
                        }
                        // Check if directory already exists
                        const newPath = join(currentPath, value);
                        if (existsSync(newPath)) {
                            return 'Directory already exists';
                        }
                    },
                });
                
                if (isCancel(newDirName)) {
                    continue;
                }
                
                const newDirPath = join(currentPath, newDirName as string);
                try {
                    mkdirSync(newDirPath, { recursive: true });
                    outro(pc.green(`Created directory: ${newDirPath}`));
                    
                    // Validate the new directory
                    if (validator) {
                        const result = await validator(newDirPath);
                        if (result !== true) {
                            outro(pc.red(typeof result === 'string' ? result : 'Invalid directory'));
                            continue;
                        }
                    }
                    
                    return newDirPath;
                } catch (error) {
                    outro(pc.red(`Failed to create directory: ${error instanceof Error ? error.message : 'Unknown error'}`));
                    continue;
                }
                
            case 'manual':
                const manualPath = await text({
                    message: 'Enter directory path:',
                    placeholder: currentPath,
                    validate: (value) => {
                        if (!value || value.trim().length === 0) {
                            return 'Path is required';
                        }
                        // Note: Cannot run async validation in text prompt
                        // Validation will be done after user submits
                    },
                });
                
                if (isCancel(manualPath)) {
                    continue;
                }
                
                const resolvedPath = resolve(manualPath as string);
                if (validator) {
                    const result = await validator(resolvedPath);
                    if (result !== true) {
                        outro(pc.red(typeof result === 'string' ? result : 'Invalid directory'));
                        continue;
                    }
                }
                
                return resolvedPath;
                
            case 'cancel':
                return null;
                
            default:
                if (statSync(choice as string).isDirectory()) {
                    currentPath = choice as string;
                }
                break;
        }
    }
}

//
// Gets directory items for the file browser
//
function getDirectoryItems(dirPath: string): Array<{name: string, path: string, isDir: boolean}> {
    try {
        const items = readdirSync(dirPath)
            .map(name => {
                const fullPath = join(dirPath, name);
                try {
                    const isDir = statSync(fullPath).isDirectory();
                    return { name, path: fullPath, isDir };
                } catch {
                    return null;
                }
            })
            .filter(item => item !== null)
            .sort((a, b) => {
                // Directories first, then alphabetical
                if (a!.isDir && !b!.isDir) return -1;
                if (!a!.isDir && b!.isDir) return 1;
                return a!.name.localeCompare(b!.name);
            }) as Array<{name: string, path: string, isDir: boolean}>;
            
        return items.slice(0, 20); // Limit to first 20 items
    } catch (error) {
        return [];
    }
}

//
// Validates directory for init command (empty or non-existent)
//
export function validateInitDirectory(path: string): boolean | string {
    if (isEmptyOrNonExistent(path)) {
        return true;
    }
    return "can't use this directory because it's not empty";
}

//
// Validates directory for other commands (existing media database)
//
export async function validateExistingDatabase(path: string): Promise<boolean | string> {
    if (!existsSync(path)) {
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
    providedDir?: string,
    nonInteractive: boolean = false
): Promise<string> {

    if (providedDir && providedDir.startsWith('s3:')) {
        return providedDir;
    }
    
    // If directory provided as argument, validate and use it
    if (providedDir) {
        const resolvedDir = resolve(providedDir);
        
        if (commandType === 'init') {
            if (validateInitDirectory(resolvedDir) === true) {
                return resolvedDir;
            } else {
                console.error(pc.red('Provided directory is not empty. Please specify an empty directory for initialization.'));
                await exit(1);
                return ''; // Never reached
            }
        } else {
            const validation = await validateExistingDatabase(resolvedDir);
            if (validation === true) {
                return resolvedDir;
            } else {
                console.error(pc.red(`Provided directory is not valid: ${validation}`));
                await exit(1);
                return ''; // Never reached
            }
        }
    }
    
    // Check if current directory is suitable
    const currentDir = process.cwd();
    
    if (commandType === 'init') {
        if (validateInitDirectory(currentDir) === true) {
            if (nonInteractive) {
                return currentDir;
            }
            
            const useCurrentDir = await confirm({
                message: `Use current directory (${currentDir}) for new database?`,
                initialValue: true,
            });
            
            if (isCancel(useCurrentDir)) {
                await exit(1);
            }
            
            if (useCurrentDir) {
                return currentDir;
            }
        } else {
            // Current directory is not empty, skip asking and go straight to picker in interactive mode
            if (nonInteractive) {
                console.error(pc.red('Current directory is not empty. Please specify an empty directory or use a different location.'));
                await exit(1);
                return ''; // Never reached but helps TypeScript
            }
        }
    } else {
        if (await isMediaDatabase(currentDir)) {
            if (nonInteractive) {
                return currentDir;
            }
            
            const useCurrentDir = await confirm({
                message: `Use current directory (${currentDir}) as media database?`,
                initialValue: true,
            });
            
            if (isCancel(useCurrentDir)) {
                await exit(1);
            }
            
            if (useCurrentDir) {
                return currentDir;
            }
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