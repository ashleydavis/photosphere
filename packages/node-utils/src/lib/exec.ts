import { exec as _exec } from 'child_process';
import { promisify } from 'util';
import { log } from "utils";

const execAsync = promisify(_exec);

//
// Executes a command using the specified tool.
//
export function exec(command: string): Promise<{ stdout: string; stderr: string }> {
    return execAsync(command);
}

//
// Runs the command and adds logging for the tool used.
//
export async function execLogged(tool: string, command: string, validate?: () => Promise<string | undefined>): Promise<{ stdout: string; stderr: string }> {
    log.verbose(`Executing ${tool} with command: "${command}"`);
    try {
        const { stdout, stderr } = await execAsync(command);
        log.tool(tool, { stdout, stderr });
        if (validate) {
            const validationFailedReason = await validate();
            if (validationFailedReason) {
                const msg = `Validation failed for command: ${command}\nReason: ${validationFailedReason}`;
                log.error(msg);
                log.info(`===\nCommand: ${command}\nCommand stdout:\n${stdout ? stdout : 'No output'}\nCommand stderr:\n${stderr ? stderr : 'No error'}\n===`);
                throw new Error(msg);
            }
        }
        return { stdout, stderr };
    }
    catch (error: any) {
        const msg = `Failed to execute command: ${command}`;
        log.exception(msg, error);
        throw new Error(msg);
    }
}