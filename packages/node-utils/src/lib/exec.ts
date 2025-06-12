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
export async function execLogged(tool: string, command: string): Promise<{ stdout: string; stderr: string }> {
    log.verbose(`Executing ${tool} with command: "${command}"`);
    const { stdout, stderr }  = await execAsync(command);
    log.tool(tool, { stdout, stderr });
    return { stdout, stderr };
}