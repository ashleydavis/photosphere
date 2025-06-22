import fs from "fs-extra";
import path from "path";
import os from "os";
import { ILog } from "utils";
import { execSync } from "child_process";
import { registerTerminationCallback } from "node-utils";

//
// File logger that writes all logs to files in the Photosphere temp directory
//
export class FileLogger implements ILog {
    private logFile: string;
    private startTime: Date;
    private command: string;
    private writeQueue: string[] = [];
    private isWriting: boolean = false;
    private isClosed: boolean = false;
    private consoleLogger: ILog;
    
    constructor(consoleLogger: ILog, command: string) {
        this.consoleLogger = consoleLogger;
        this.startTime = new Date();
        this.command = command;
        
        // Create logs directory in Photosphere temp
        const photosphereTempDir = path.join(os.tmpdir(), 'photosphere');
        const logsDir = path.join(photosphereTempDir, 'logs');
        fs.ensureDirSync(logsDir);
        
        // Create log file with timestamp
        const timestamp = this.startTime.toISOString().replace(/[:.]/g, '-').slice(0, 19);
        this.logFile = path.join(logsDir, `psi-${timestamp}.log`);
        
        // Write initial log header synchronously
        this.writeLogHeaderSync();
        
        // Register termination callback to flush logs
        registerTerminationCallback(async () => {
            await this.close();
        });
    }
    
    private writeLogHeaderSync(): void {
        const lines = [
            '='.repeat(80),
            `Photosphere CLI Log`,
            `Started: ${this.startTime.toISOString()}`,
            `Command: ${this.command}`,
            `Working Directory: ${process.cwd()}`,
            '='.repeat(80),
            '',
            '--- System Information ---',
            `Platform: ${os.platform()}`,
            `Architecture: ${os.arch()}`,
            `OS Release: ${os.release()}`,
            `Node Version: ${process.version}`,
            '',
            '--- Photosphere Version ---',
            this.getPhotosphereVersion(),
            '',
            '--- Tool Versions ---',
            this.getImageMagickVersion(),
            this.getFFmpegVersion(),
            '',
            '--- Log Start ---',
            ''
        ];
        
        const header = lines.join('\n');
        fs.writeFileSync(this.logFile, header);
    }
    
    private getPhotosphereVersion(): string {
        try {
            const packageJsonPath = path.join(__dirname, '../../package.json');
            const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
            return `Photosphere CLI: ${packageJson.version}`;
        } catch (error) {
            return `Photosphere CLI: version unknown (${error instanceof Error ? error.message : 'unknown error'})`;
        }
    }
    
    private getImageMagickVersion(): string {
        try {
            const output = execSync('magick -version', { encoding: 'utf8', timeout: 5000 });
            const firstLine = output.split('\n')[0];
            return `ImageMagick: ${firstLine}`;
        } catch (error) {
            return `ImageMagick: not available (${error instanceof Error ? error.message : 'unknown error'})`;
        }
    }
    
    private getFFmpegVersion(): string {
        try {
            const output = execSync('ffmpeg -version', { encoding: 'utf8', timeout: 5000 });
            const firstLine = output.split('\n')[0];
            return `FFmpeg: ${firstLine}`;
        } catch (error) {
            return `FFmpeg: not available (${error instanceof Error ? error.message : 'unknown error'})`;
        }
    }
    
    private writeToFile(level: string, message: string): void {
        if (this.isClosed) {
            return;
        }
        
        const timestamp = new Date().toISOString();
        const logEntry = `[${timestamp}] [${level.toUpperCase()}] ${message}\n`;
        
        // Add to queue for async writing
        this.writeQueue.push(logEntry);
        
        // Start processing queue if not already doing so
        this.processWriteQueue();
    }
    
    private async processWriteQueue(): Promise<void> {
        if (this.isWriting || this.writeQueue.length === 0) {
            return;
        }
        
        this.isWriting = true;
        
        try {
            while (this.writeQueue.length > 0) {
                const entries = this.writeQueue.splice(0); // Take all pending entries
                const content = entries.join('');
                await fs.appendFile(this.logFile, content);
            }
        } catch (error) {
            // Silently ignore file write errors - we don't want logging to break the app
        } finally {
            this.isWriting = false;
        }
    }
    
    info(message: string): void {
        this.writeToFile('info', message);
        this.consoleLogger.info(message);
    }
    
    verbose(message: string): void {
        this.writeToFile('verbose', message);
        this.consoleLogger.verbose(message);
    }
    
    error(message: string): void {
        this.writeToFile('error', message);
        this.consoleLogger.error(message);
    }
    
    exception(message: string, error: Error): void {
        const fullMessage = `${message}\nStack trace: ${error.stack || error.message || error}`;
        this.writeToFile('exception', fullMessage);
        this.consoleLogger.exception(message, error);
    }
    
    warn(message: string): void {
        this.writeToFile('warn', message);
        this.consoleLogger.warn(message);
    }
    
    debug(message: string): void {
        this.writeToFile('debug', message);
        this.consoleLogger.debug(message);
    }
    
    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        if (data.stdout) {
            this.writeToFile('tool', `== ${tool} stdout ==\n${data.stdout}`);
        }
        if (data.stderr) {
            this.writeToFile('tool', `== ${tool} stderr ==\n${data.stderr}`);
        }
        this.consoleLogger.tool(tool, data);
    }
    
    //
    // Write final log footer when command completes and flush all pending writes
    //
    async close(): Promise<void> {
        if (this.isClosed) {
            return;
        }
        
        this.isClosed = true;
        
        const endTime = new Date();
        const duration = endTime.getTime() - this.startTime.getTime();
        
        const footer = [
            '',
            '--- Log End ---',
            `Completed: ${endTime.toISOString()}`,
            `Duration: ${duration}ms (${(duration / 1000).toFixed(2)}s)`,
            '='.repeat(80),
            ''
        ].join('\n');
        
        // Add footer to queue and flush everything asynchronously
        this.writeQueue.push(footer);
        
        // Wait for any pending writes to complete
        while (this.isWriting) {
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        
        // Final flush of remaining content
        try {
            if (this.writeQueue.length > 0) {
                const content = this.writeQueue.join('');
                await fs.appendFile(this.logFile, content);
                this.writeQueue = [];
            }
        } catch (error) {
            // Silently ignore file write errors during close
        }
    }
    
    //
    // Get the path to the current log file
    //
    getLogFilePath(): string {
        return this.logFile;
    }
}