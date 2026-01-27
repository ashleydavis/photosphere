import * as fs from "fs/promises";
import { ensureDirSync } from "node-utils";
import path from "path";
import os from "os";
import type { ILog } from "utils";
import type { IWorkerLogMessage } from "./worker-log-electron";
import { Image, Video } from "tools";

//
// File logger for Electron main process.
// Writes all logs to files in the Photosphere logs directory.
// Similar to the CLI file logger but adapted for Electron.
//
export class FileLoggerElectron implements ILog {
    private logFile: string;
    private errorLogFile: string;
    private logsDir: string;
    private startTime: Date;
    private writeQueue: string[] = [];
    private errorWriteQueue: string[] = [];
    private isWriting: boolean = false;
    private isWritingErrors: boolean = false;
    private isClosed: boolean = false;
    private hasErrors: boolean = false;
    private errorFileHeaderWritten: boolean = false;
    
    private constructor(logsDir: string, logFile: string, errorLogFile: string, startTime: Date) {
        this.logsDir = logsDir;
        this.logFile = logFile;
        this.errorLogFile = errorLogFile;
        this.startTime = startTime;
    }
    
    static async create(userDataPath: string): Promise<FileLoggerElectron> {
        const startTime = new Date();
        
        // Create logs directory in Photosphere temp (like CLI) for consistency
        const photosphereTempDir = path.join(os.tmpdir(), 'photosphere');
        const logsDir = path.join(photosphereTempDir, 'logs');
        ensureDirSync(logsDir);
        
        // Create log file with timestamp
        const timestamp = startTime.toISOString().replace(/[:.]/g, '-').slice(0, 19);
        const logFile = path.join(logsDir, `photosphere-${timestamp}.log`);
        const errorLogFile = path.join(logsDir, `photosphere-${timestamp}-errors.log`);
        
        // Create the logger instance
        const logger = new FileLoggerElectron(logsDir, logFile, errorLogFile, startTime);
        
        // Write initial log headers for both files
        await logger.writeLogHeader();
        await logger.writeErrorLogHeader();
        
        return logger;
    }
    
    private async writeLogHeader(): Promise<void> {
        const lines = [
            '='.repeat(80),
            `Photosphere Desktop Log`,
            `Started: ${this.startTime.toISOString()}`,
            '='.repeat(80),
            '',
            '--- System Information ---',
            `Platform: ${os.platform()}`,
            `Architecture: ${os.arch()}`,
            `OS Release: ${os.release()}`,
            `Node Version: ${process.version}`,
            `Electron Version: ${process.versions.electron || 'unknown'}`,
            `Chrome Version: ${process.versions.chrome || 'unknown'}`,
            '',
            '--- Tool Versions ---',
            await this.getImageMagickVersion(),
            await this.getFFmpegVersion(),
            await this.getFFprobeVersion(),
            '',
            '--- Log Start ---',
            ''
        ];
        
        const header = lines.join('\n');
        await fs.writeFile(this.logFile, header);
    }
    
    private async writeErrorLogHeader(): Promise<void> {
        const header = [
            '='.repeat(80),
            `Photosphere Desktop Error Log`,
            `Started: ${this.startTime.toISOString()}`,
            '='.repeat(80),
            '',
            '--- System Information ---',
            `Platform: ${os.platform()}`,
            `Architecture: ${os.arch()}`,
            `OS Release: ${os.release()}`,
            `Node Version: ${process.version}`,
            `Electron Version: ${process.versions.electron || 'unknown'}`,
            `Chrome Version: ${process.versions.chrome || 'unknown'}`,
            '',
            '--- Tool Versions ---',
            await this.getImageMagickVersion(),
            await this.getFFmpegVersion(),
            await this.getFFprobeVersion(),
            '',
            'If this file contains nothing below, it means there were no errors.',
            '',
            '--- Error Log Start ---',
            ''
        ].join('\n');
        await fs.writeFile(this.errorLogFile, header);
        this.errorFileHeaderWritten = true;
    }
    
    private async getImageMagickVersion(): Promise<string> {
        try {
            const result = await Image.verifyImageMagick();
            if (result.available) {
                return `ImageMagick: ${result.version} (${result.type})`;
            }
            else {
                return `ImageMagick: not found`;
            }
        }
        catch (error) {
            return `ImageMagick: error checking version`;
        }
    }
    
    private async getFFmpegVersion(): Promise<string> {
        try {
            const result = await Video.verifyFfmpeg();
            if (result.available) {
                return `FFmpeg: ${result.version}`;
            }
            else {
                return `FFmpeg: not found`;
            }
        }
        catch (error) {
            return `FFmpeg: error checking version`;
        }
    }
    
    private async getFFprobeVersion(): Promise<string> {
        try {
            const result = await Video.verifyFfprobe();
            if (result.available) {
                return `FFprobe: ${result.version}`;
            }
            else {
                return `FFprobe: not found`;
            }
        }
        catch (error) {
            return `FFprobe: error checking version`;
        }
    }
        
    private writeToFile(level: string, message: string, source?: string): void {
        if (this.isClosed) {
            return;
        }
        
        const timestamp = new Date().toISOString();
        const sourcePrefix = source ? `[${source}] ` : '';
        const logEntry = `[${timestamp}] [${level.toUpperCase()}] ${sourcePrefix}${message}\n`;
        
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
        }
        catch (error) {
            // Silently ignore file write errors - we don't want logging to break the app
        }
        finally {
            this.isWriting = false;
        }
    }
    
    private writeToErrorFile(level: string, message: string, source?: string): void {
        if (this.isClosed) {
            return;
        }
        
        this.hasErrors = true;
        
        const timestamp = new Date().toISOString();
        const sourcePrefix = source ? `[${source}] ` : '';
        const logEntry = `[${timestamp}] [${level.toUpperCase()}] ${sourcePrefix}${message}\n`;
        
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
            while (this.errorWriteQueue.length > 0) {
                const entries = this.errorWriteQueue.splice(0); // Take all pending entries
                const content = entries.join('');
                await fs.appendFile(this.errorLogFile, content);
            }
        }
        catch (error) {
            // Silently ignore file write errors - we don't want logging to break the app
        }
        finally {
            this.isWritingErrors = false;
        }
    }
    
    get verboseEnabled(): boolean {
        return false; // Main process doesn't need verbose logging by default
    }

    info(message: string, source?: string): void {
        this.writeToFile('info', message, source);
        console.log(source ? `[${source}] ${message}` : message);
    }
    
    verbose(message: string, source?: string): void {
        this.writeToFile('verbose', message, source);
    }
    
    error(message: string, source?: string): void {
        this.writeToFile('error', message, source);
        this.writeToErrorFile('error', message, source);
        console.error(source ? `[${source}] ${message}` : message);
    }
    
    exception(message: string, error: Error, source?: string): void {
        const fullMessage = `${message}\nStack trace: ${error.stack || error.message || error}`;
        this.writeToFile('exception', fullMessage, source);
        this.writeToErrorFile('exception', fullMessage, source);
        console.error(source ? `[${source}] ${message}` : message);
        console.error(error.stack || error.message || error);
    }
    
    warn(message: string, source?: string): void {
        this.writeToFile('warn', message, source);
        this.writeToErrorFile('warn', message, source);
        console.warn(source ? `[${source}] ${message}` : message);
    }
    
    debug(message: string, source?: string): void {
        this.writeToFile('debug', message, source);
    }
    
    tool(tool: string, data: { stdout?: string; stderr?: string }, source?: string): void {
        if (data.stdout) {
            this.writeToFile('tool', `== ${tool} stdout ==\n${data.stdout}`, source);
        }
        if (data.stderr) {
            this.writeToFile('tool', `== ${tool} stderr ==\n${data.stderr}`, source);
        }
    }
    
    //
    // Handle log message from a worker (utility process or renderer)
    //
    handleWorkerLogMessage(message: IWorkerLogMessage, source: string): void {
        const level = message.level;
        const logMessage = message.message;
        const error = message.error;
        const toolData = message.toolData;

        switch (level) {
            case 'info':
                this.info(logMessage, source);
                break;
            case 'verbose':
                this.verbose(logMessage, source);
                break;
            case 'error':
                this.error(logMessage, source);
                break;
            case 'exception':
                this.writeToFile('exception', error ? `${logMessage}\n${error}` : logMessage, source);
                this.writeToErrorFile('exception', error ? `${logMessage}\n${error}` : logMessage, source);
                console.error(`[${source}] ${logMessage}`);
                if (error) {
                    console.error(`[${source}] ${error}`);
                }
                break;
            case 'warn':
                this.warn(logMessage, source);
                break;
            case 'debug':
                this.debug(logMessage, source);
                break;
            case 'tool':
                if (toolData) {
                    this.tool(logMessage, toolData, source);
                    if (toolData.stdout) {
                        console.log(`[${source}] == ${logMessage} stdout ==\n${toolData.stdout}`);
                    }
                    if (toolData.stderr) {
                        console.log(`[${source}] == ${logMessage} stderr ==\n${toolData.stderr}`);
                    }
                }
                break;
        }
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
        }
        catch (error) {
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
        }
        catch (error) {
            // Silently ignore file write errors during close
        }
    }
    
    //
    // Get the path to the current log file
    //
    getLogFilePath(): string {
        return this.logFile;
    }
    
    //
    // Get the path to the logs directory
    //
    getLogsDirectory(): string {
        return this.logsDir;
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
