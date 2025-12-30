import * as fs from "fs/promises";
import { ensureDirSync } from "node-utils";
import path from "path";
import os from "os";
import { ILog } from "utils";
import { registerTerminationCallback } from "node-utils";
import { Image, Video } from "tools";
import { version } from "./version";
import { buildMetadata } from "./build-metadata";

//
// File logger that writes all logs to files in the Photosphere temp directory
//
export class FileLogger implements ILog {
    private logFile: string;
    private errorLogFile: string;
    private startTime: Date;
    private command: string;
    private writeQueue: string[] = [];
    private errorWriteQueue: string[] = [];
    private isWriting: boolean = false;
    private isWritingErrors: boolean = false;
    private isClosed: boolean = false;
    private hasErrors: boolean = false;
    private errorFileHeaderWritten: boolean = false;
    private consoleLogger: ILog;
    
    private constructor(consoleLogger: ILog, command: string, logFile: string, errorLogFile: string, startTime: Date) {
        this.consoleLogger = consoleLogger;
        this.command = command;
        this.logFile = logFile;
        this.errorLogFile = errorLogFile;
        this.startTime = startTime;
        
        // Register termination callback to flush logs
        registerTerminationCallback(async () => {
            await this.close();
        });
    }
    
    static async create(consoleLogger: ILog, command: string): Promise<FileLogger> {
        const startTime = new Date();
        
        // Create logs directory in Photosphere temp
        const photosphereTempDir = path.join(os.tmpdir(), 'photosphere');
        const logsDir = path.join(photosphereTempDir, 'logs');
        ensureDirSync(logsDir);
        
        // Create log file with timestamp
        const timestamp = startTime.toISOString().replace(/[:.]/g, '-').slice(0, 19);
        const logFile = path.join(logsDir, `psi-${timestamp}.log`);
        const errorLogFile = path.join(logsDir, `psi-${timestamp}-errors.log`);
        
        // Create the logger instance
        const logger = new FileLogger(consoleLogger, command, logFile, errorLogFile, startTime);
        
        // Write initial log header
        await logger.writeLogHeader();
        
        return logger;
    }
    
    private async writeLogHeader(): Promise<void> {
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
            version,
            `Build Commit: ${buildMetadata.commitHash}`,
            `Build Date: ${buildMetadata.buildDate}`,
            `Nightly Build: ${buildMetadata.isNightly}`,
            '',
            '--- Tool Versions ---',
            await this.getImageMagickVersion(),
            await this.getFFmpegVersion(),
            await this.getFFprobeVersion(),
            '',
            `--- Command ---`,
            process.argv.join(' '),
            '--- Log Start ---',
            ''
        ];
        
        const header = lines.join('\n');
        await fs.writeFile(this.logFile, header);
    }
    
    private async getImageMagickVersion(): Promise<string> {
        try {
            const result = await Image.verifyImageMagick();
            if (result.available) {
                return `ImageMagick: ${result.version} (${result.type})`;
            } else {
                return `ImageMagick: not found`;
            }
        } catch (error) {
            return `ImageMagick: error checking version`;
        }
    }
    
    private async getFFmpegVersion(): Promise<string> {
        try {
            const result = await Video.verifyFfmpeg();
            if (result.available) {
                return `FFmpeg: ${result.version}`;
            } else {
                return `FFmpeg: not found`;
            }
        } catch (error) {
            return `FFmpeg: error checking version`;
        }
    }
    
    private async getFFprobeVersion(): Promise<string> {
        try {
            const result = await Video.verifyFfprobe();
            if (result.available) {
                return `FFprobe: ${result.version}`;
            } else {
                return `FFprobe: not found`;
            }
        } catch (error) {
            return `FFprobe: error checking version`;
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
    
    private writeToErrorFile(level: string, message: string): void {
        if (this.isClosed) {
            return;
        }
        
        this.hasErrors = true;
        
        const timestamp = new Date().toISOString();
        const logEntry = `[${timestamp}] [${level.toUpperCase()}] ${message}\n`;
        
        // Add to error queue for async writing
        this.errorWriteQueue.push(logEntry);
        
        // Start processing error queue if not already doing so
        this.processErrorWriteQueue();
    }
    
    private async processErrorWriteQueue(): Promise<void> {
        if (this.isWritingErrors || this.errorWriteQueue.length === 0) {
            return;
        }
        
        this.isWritingErrors = true;
        
        try {
            // Create error log file with header if it doesn't exist yet
            if (!this.errorFileHeaderWritten) {
                const header = [
                    '='.repeat(80),
                    `Photosphere CLI Error Log`,
                    `Started: ${this.startTime.toISOString()}`,
                    `Command: ${this.command}`,
                    `Working Directory: ${process.cwd()}`,
                    '='.repeat(80),
                    '',
                    '--- Error Log Start ---',
                    ''
                ].join('\n');
                await fs.writeFile(this.errorLogFile, header);
                this.errorFileHeaderWritten = true;
            }
            
            while (this.errorWriteQueue.length > 0) {
                const entries = this.errorWriteQueue.splice(0); // Take all pending entries
                const content = entries.join('');
                await fs.appendFile(this.errorLogFile, content);
            }
        } catch (error) {
            // Silently ignore file write errors - we don't want logging to break the app
        } finally {
            this.isWritingErrors = false;
        }
    }
    
    get verboseEnabled(): boolean {
        return this.consoleLogger.verboseEnabled;
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
        this.writeToErrorFile('error', message);
        this.consoleLogger.error(message);
    }
    
    exception(message: string, error: Error): void {
        const fullMessage = `${message}\nStack trace: ${error.stack || error.message || error}`;
        this.writeToFile('exception', fullMessage);
        this.writeToErrorFile('exception', fullMessage);
        this.consoleLogger.exception(message, error);
    }
    
    warn(message: string): void {
        this.writeToFile('warn', message);
        this.writeToErrorFile('warn', message);
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
        
        // Wait for any pending error writes to complete
        while (this.isWritingErrors) {
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        
        // Final flush of remaining error content
        try {
            if (this.errorWriteQueue.length > 0) {
                const content = this.errorWriteQueue.join('');
                await fs.appendFile(this.errorLogFile, content);
                this.errorWriteQueue = [];
            }
            
            // Add footer to error log if errors were logged
            if (this.hasErrors) {
                const errorFooter = [
                    '',
                    '--- Error Log End ---',
                    `Completed: ${endTime.toISOString()}`,
                    '='.repeat(80),
                    ''
                ].join('\n');
                await fs.appendFile(this.errorLogFile, errorFooter);
            }
        } catch (error) {
            // Silently ignore file write errors during close
        }
        
        // Show error file location if errors were logged
        if (this.hasErrors) {
            console.log('');
            console.log(`Errors, warnings, and exceptions were logged to: ${this.errorLogFile}`);
        }
    }
    
    //
    // Get the path to the current log file
    //
    getLogFilePath(): string {
        return this.logFile;
    }
    
    //
    // Check if any errors, warnings, or exceptions were logged
    //
    hasLoggedErrors(): boolean {
        return this.hasErrors;
    }
    
    //
    // Get the path to the error log file
    //
    getErrorLogFilePath(): string {
        return this.errorLogFile;
    }
}