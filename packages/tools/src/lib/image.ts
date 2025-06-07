import { exec } from 'child_process';
import { promisify } from 'util';
import { existsSync, statSync } from 'fs';
import { join, dirname } from 'path';
import { homedir, platform } from 'os';
import type { AssetInfo, Dimensions, ResizeOptions, ImageMagickConfig } from './types';

const execAsync = promisify(exec);

export class Image {
    private filePath: string;
    private _info: AssetInfo | null = null;
    private static convertCommand: string = 'magick convert';
    private static identifyCommand: string = 'magick identify';
    private static isInitialized: boolean = false;

    constructor(filePath: string) {
        if (!existsSync(filePath)) {
            throw new Error(`File not found: ${filePath}`);
        }
        this.filePath = filePath;
        
        // Initialize ImageMagick commands on first use
        if (!Image.isInitialized) {
            Image.initializeCommands();
        }
    }

    /**
     * Configure custom paths for ImageMagick binaries
     */
    static configure(config: ImageMagickConfig) {
        if (config.convertPath) {
            Image.convertCommand = config.convertPath;
        }
        if (config.identifyPath) {
            Image.identifyCommand = config.identifyPath;
        }
        Image.isInitialized = true;
    }

    /**
     * Initialize ImageMagick commands by checking multiple locations
     */
    private static async initializeCommands() {
        if (Image.isInitialized) return;

        // Get the directory of the current executable
        const currentDir = process.cwd();
        const execDir = dirname(process.execPath);
        const toolsDir = join(homedir(), '.photosphere', 'tools');

        // Possible paths to check for magick binary
        // PRIORITY ORDER: Local directories first, then system PATH
        const possiblePaths = [
            // 1. Photosphere tools directory (highest priority)
            join(toolsDir, 'magick'),
            join(toolsDir, 'magick.exe'),
            
            // 2. Current working directory
            join(currentDir, 'squashfs-root', 'usr', 'bin', 'magick'),
            join(currentDir, 'magick'),
            join(currentDir, 'magick.exe'),
            
            // 3. Directory of the executable (for bundled apps)
            join(execDir, 'magick'),
            join(execDir, 'magick.exe'),
            
            // 4. System PATH (lowest priority)
            'magick',
        ];

        // Try to find working magick command
        for (const magickPath of possiblePaths) {
            try {
                // Test magick command
                const { stdout } = await execAsync(`"${magickPath}" -version`);
                
                // If we get here, magick command works
                // Store the command with appropriate subcommands
                Image.convertCommand = `"${magickPath}" convert`;
                Image.identifyCommand = `"${magickPath}" identify`;
                Image.isInitialized = true;
                
                // Get version info
                const versionMatch = stdout.match(/Version: ImageMagick ([\d.-]+)/);
                const version = versionMatch ? versionMatch[1] : 'unknown';
                
                const isLocal = magickPath.startsWith(currentDir) || magickPath.startsWith(execDir) || magickPath.startsWith(toolsDir);
                console.log(`Using ${isLocal ? 'local' : 'system'} ImageMagick: ${magickPath}`);
                console.log(`ImageMagick version: ${version}`);
                return;
            } catch {
                // Try next path
                continue;
            }
        }

        // If we get here, we couldn't find ImageMagick
        console.warn('ImageMagick (magick command) not found. Please install ImageMagick 7.0 or later.');
        Image.isInitialized = true;
    }

    /**
     * Verify that ImageMagick is available
     */
    static async verifyImageMagick(): Promise<{ available: boolean; version?: string; error?: string }> {
        try {
            // Initialize if not already done
            if (!Image.isInitialized) {
                await Image.initializeCommands();
            }
            
            // Get the magick path from the convertCommand
            const magickPath = Image.convertCommand.match(/"([^"]+)"/)?.[1] || Image.convertCommand.split(' ')[0];
            const { stdout } = await execAsync(`"${magickPath}" -version`);
            
            const versionMatch = stdout.match(/Version: ImageMagick ([\d.-]+)/);
            return {
                available: true,
                version: versionMatch ? versionMatch[1] : 'unknown'
            };
        } catch (error) {
            return {
                available: false,
                error: `ImageMagick not found. Make sure ImageMagick 7.0+ is installed and the 'magick' command is available.`
            };
        }
    }

    private async getImageInfo(): Promise<AssetInfo> {
        if (this._info) {
            return this._info;
        }

        try {
            // Get file stats for modification time
            const stats = statSync(this.filePath);
            
            // Get format, dimensions, file size, and color space
            const command = `${Image.identifyCommand} -format "%m %w %h %b %[colorspace]" "${this.filePath}"`;
            const { stdout } = await execAsync(command);
            
            const parts = stdout.trim().split(' ');
            const format = parts[0].toLowerCase();
            const width = parseInt(parts[1]);
            const height = parseInt(parts[2]);
            const fileSizeStr = parts[3];
            const colorSpace = parts[4];
            
            // Parse file size (can be in B, KB, MB format)
            let fileSize = 0;
            if (fileSizeStr.endsWith('B')) {
                fileSize = parseInt(fileSizeStr);
            } else if (fileSizeStr.endsWith('KB')) {
                fileSize = parseFloat(fileSizeStr) * 1024;
            } else if (fileSizeStr.endsWith('MB')) {
                fileSize = parseFloat(fileSizeStr) * 1024 * 1024;
            } else {
                fileSize = parseInt(fileSizeStr);
            }

            // Determine MIME type based on format
            const mimeTypes: Record<string, string> = {
                'jpeg': 'image/jpeg',
                'jpg': 'image/jpeg',
                'png': 'image/png',
                'gif': 'image/gif',
                'webp': 'image/webp',
                'bmp': 'image/bmp',
                'tiff': 'image/tiff',
                'tif': 'image/tiff',
                'svg': 'image/svg+xml',
                'ico': 'image/x-icon',
                'heic': 'image/heic',
                'heif': 'image/heif'
            };

            // Get EXIF data for created date
            let createdAt: Date | undefined;
            try {
                const exifData = await this.getExifData();
                if (exifData.DateTimeOriginal) {
                    // Parse EXIF date format: "2023:12:25 14:30:00"
                    const dateStr = exifData.DateTimeOriginal.replace(/^(\d{4}):(\d{2}):(\d{2})/, '$1-$2-$3');
                    createdAt = new Date(dateStr);
                }
            } catch {
                // Ignore EXIF errors
            }

            this._info = {
                type: 'image',
                format,
                mimeType: mimeTypes[format] || `image/${format}`,
                
                filePath: this.filePath,
                fileSize: fileSize || stats.size,
                
                dimensions: { width, height },
                
                colorSpace,
                createdAt,
                modifiedAt: stats.mtime,
                
                // Images don't have these properties
                duration: undefined,
                fps: undefined,
                bitrate: undefined,
                hasAudio: false
            };

            return this._info;
        } catch (error) {
            throw new Error(`Failed to get image info: ${error}`);
        }
    }

    async getDimensions(): Promise<Dimensions> {
        const info = await this.getImageInfo();
        return info.dimensions;
    }

    async getFormat(): Promise<string> {
        const info = await this.getImageInfo();
        return info.format;
    }

    async getMimeType(): Promise<string> {
        const info = await this.getImageInfo();
        return info.mimeType;
    }

    async getInfo(): Promise<AssetInfo> {
        return await this.getImageInfo();
    }

    /**
     * Get EXIF data from the image
     */
    async getExifData(): Promise<Record<string, string>> {
        try {
            const command = `${Image.identifyCommand} -format "%[EXIF:*]" "${this.filePath}"`;
            const { stdout } = await execAsync(command);
            
            const exifData: Record<string, string> = {};
            const lines = stdout.trim().split('\n');
            
            for (const line of lines) {
                const match = line.match(/exif:([^=]+)=(.*)/);
                if (match) {
                    exifData[match[1]] = match[2];
                }
            }
            
            return exifData;
        } catch (error) {
            throw new Error(`Failed to get EXIF data: ${error}`);
        }
    }

    async resize(options: ResizeOptions, outputPath?: string): Promise<Image> {
        const { width, height, quality, format, maintainAspectRatio = true } = options;

        if (!width && !height) {
            throw new Error('Either width or height must be specified');
        }

        // Build the resize geometry string
        let geometry = '';
        if (width && height) {
            geometry = maintainAspectRatio ? `${width}x${height}` : `${width}x${height}!`;
        } else if (width) {
            geometry = `${width}x`;
        } else if (height) {
            geometry = `x${height}`;
        }

        // Build the convert command
        let command = `${Image.convertCommand} "${this.filePath}" -resize ${geometry}`;

        // Add quality if specified
        if (quality !== undefined) {
            if (quality < 0 || quality > 100) {
                throw new Error('Quality must be between 0 and 100');
            }
            command += ` -quality ${quality}`;
        }

        // Determine output path
        const output = outputPath || this.generateOutputPath(format);
        
        // Add format conversion if needed
        if (format) {
            command += ` "${output}"`;
        } else {
            command += ` "${output}"`;
        }

        try {
            await execAsync(command);
            return new Image(output);
        } catch (error) {
            throw new Error(`Failed to resize image: ${error}`);
        }
    }

    async saveAs(outputPath: string, options?: { quality?: number; format?: ResizeOptions['format'] }): Promise<Image> {
        let command = `${Image.convertCommand} "${this.filePath}"`;

        if (options?.quality !== undefined) {
            if (options.quality < 0 || options.quality > 100) {
                throw new Error('Quality must be between 0 and 100');
            }
            command += ` -quality ${options.quality}`;
        }

        command += ` "${outputPath}"`;

        try {
            await execAsync(command);
            return new Image(outputPath);
        } catch (error) {
            throw new Error(`Failed to save image: ${error}`);
        }
    }

    private generateOutputPath(format?: string): string {
        const pathParts = this.filePath.split('.');
        const extension = pathParts.pop();
        const basePath = pathParts.join('.');
        const newExtension = format || extension;
        return `${basePath}_resized.${newExtension}`;
    }

    getPath(): string {
        return this.filePath;
    }
}