import fs from "fs-extra";
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
    private startTime: Date;
    private command: string;
    private writeQueue: string[] = [];
    private isWriting: boolean = false;
    private isClosed: boolean = false;
    private consoleLogger: ILog;
    
    private constructor(consoleLogger: ILog, command: string, logFile: string, startTime: Date) {
        this.consoleLogger = consoleLogger;
        this.command = command;
        this.logFile = logFile;
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
        fs.ensureDirSync(logsDir);
        
        // Create log file with timestamp
        const timestamp = startTime.toISOString().replace(/[:.]/g, '-').slice(0, 19);
        const logFile = path.join(logsDir, `psi-${timestamp}.log`);
        
        // Create the logger instance
        const logger = new FileLogger(consoleLogger, command, logFile, startTime);
        
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