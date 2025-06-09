import { exec } from 'child_process';
import { promisify } from 'util';
import { existsSync, statSync } from 'fs';
import { platform } from 'os';
import type { AssetInfo, Dimensions, ResizeOptions, ImageMagickConfig } from './types';

const execAsync = promisify(exec);

export class Image {
    private filePath: string;
    private _info: AssetInfo | null = null;
    private static convertCommand: string = 'magick convert';
    private static identifyCommand: string = 'magick identify';
    private static isInitialized: boolean = false;
    private static imageMagickType: 'modern' | 'legacy' | 'none' = 'none';

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
     * Initialize ImageMagick commands by checking system PATH
     */
    private static async initializeCommands() {
        if (Image.isInitialized) return;

        try {
            // First try modern ImageMagick (magick command)
            const { stdout } = await execAsync('magick -version');
            
            // If we get here, modern magick command works
            Image.convertCommand = 'magick convert';
            Image.identifyCommand = 'magick identify';
            Image.imageMagickType = 'modern';
            Image.isInitialized = true;
            
            // Get version info
            const versionMatch = stdout.match(/Version: ImageMagick ([\d.-]+)/);
            const version = versionMatch ? versionMatch[1] : 'unknown';
            
            console.log(`Using modern ImageMagick: magick`);
            console.log(`ImageMagick version: ${version}`);
        } catch {
            try {
                // Try legacy ImageMagick (convert/identify commands)
                const [convertResult, identifyResult] = await Promise.all([
                    execAsync('convert -version'),
                    execAsync('identify -version')
                ]);
                
                // If we get here, legacy commands work
                Image.convertCommand = 'convert';
                Image.identifyCommand = 'identify';
                Image.imageMagickType = 'legacy';
                Image.isInitialized = true;
                
                // Get version info from convert command
                const versionMatch = convertResult.stdout.match(/Version: ImageMagick ([\d.-]+)/);
                const version = versionMatch ? versionMatch[1] : 'unknown';
                
                console.log(`Using legacy ImageMagick: convert/identify`);
                console.log(`ImageMagick version: ${version}`);
            } catch {
                // Neither modern nor legacy ImageMagick found
                Image.imageMagickType = 'none';
                Image.isInitialized = true;
            }
        }
    }

    /**
     * Verify that ImageMagick is available
     */
    static async verifyImageMagick(): Promise<{ available: boolean; version?: string; error?: string; type?: 'modern' | 'legacy' }> {
        // Initialize commands if not already done
        await Image.initializeCommands();
        
        if (Image.imageMagickType === 'modern') {
            try {
                const { stdout } = await execAsync('magick -version');
                const versionMatch = stdout.match(/Version: ImageMagick ([\d.-]+)/);
                return {
                    available: true,
                    version: versionMatch ? versionMatch[1] : 'unknown',
                    type: 'modern'
                };
            } catch (error) {
                return {
                    available: false,
                    error: `Modern ImageMagick 'magick' command failed: ${error}`
                };
            }
        } else if (Image.imageMagickType === 'legacy') {
            try {
                const { stdout } = await execAsync('convert -version');
                const versionMatch = stdout.match(/Version: ImageMagick ([\d.-]+)/);
                return {
                    available: true,
                    version: versionMatch ? versionMatch[1] : 'unknown',
                    type: 'legacy'
                };
            } catch (error) {
                return {
                    available: false,
                    error: `Legacy ImageMagick 'convert' command failed: ${error}`
                };
            }
        } else {
            return {
                available: false,
                error: `ImageMagick not found. Please install ImageMagick and ensure either 'magick' or 'convert'/'identify' commands are available.`
            };
        }
    }

    /**
     * Get the type of ImageMagick installation
     */
    static getImageMagickType(): 'modern' | 'legacy' | 'none' {
        return Image.imageMagickType;
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

    /**
     * Extract the dominant color from the image using ImageMagick
     * Returns RGB values as [r, g, b] array
     */
    async getDominantColor(): Promise<[number, number, number]> {
        try {
            // Method 1: Simple resize to 1x1 pixel (fastest, good for average color)
            const command = `${Image.convertCommand} "${this.filePath}" -resize 1x1! -format "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]" info:`;
            const { stdout } = await execAsync(command);
            
            const rgbString = stdout.trim();
            const rgbValues = rgbString.split(',').map(val => parseInt(val.trim()));
            
            if (rgbValues.length === 3 && rgbValues.every(val => !isNaN(val) && val >= 0 && val <= 255)) {
                return [rgbValues[0], rgbValues[1], rgbValues[2]];
            } else {
                throw new Error(`Invalid RGB values: ${rgbString}`);
            }
        } catch (error) {
            throw new Error(`Failed to extract dominant color: ${error}`);
        }
    }

    /**
     * Extract the dominant color using histogram analysis with k-means clustering
     * This method provides more accurate dominant color but is slower
     * Returns RGB values as [r, g, b] array
     */
    async getDominantColorHistogram(colorCount: number = 5): Promise<[number, number, number]> {
        try {
            // First resize to optimize performance, then use histogram analysis
            let command: string;
            
            if (Image.imageMagickType === 'modern') {
                // Use k-means clustering for ImageMagick 7 (more accurate)
                command = `${Image.convertCommand} "${this.filePath}" -resize 500x500 -kmeans ${colorCount} -format "%c" histogram:info:`;
            } else {
                // Use color reduction for legacy ImageMagick
                command = `${Image.convertCommand} "${this.filePath}" -resize 500x500 +dither -colors ${colorCount} -format "%c" histogram:info:`;
            }
            
            const { stdout } = await execAsync(command);
            
            // Parse histogram output to find the most frequent color
            const lines = stdout.trim().split('\n');
            let maxCount = 0;
            let dominantColor: [number, number, number] = [0, 0, 0];
            
            for (const line of lines) {
                if (line.trim()) {
                    // Parse line like: "   1234: (255,128,64) #FF8040 srgb(255,128,64)"
                    // or "   30065: (48.4086,48.7393,51.1362) #303133 srgb(18.9837%,19.1135%,20.0534%)"
                    const countMatch = line.match(/^\s*(\d+):/);
                    const rgbMatch = line.match(/\(([0-9.]+),([0-9.]+),([0-9.]+)\)/);
                    
                    if (countMatch && rgbMatch) {
                        const count = parseInt(countMatch[1]);
                        const r = Math.round(parseFloat(rgbMatch[1]));
                        const g = Math.round(parseFloat(rgbMatch[2]));
                        const b = Math.round(parseFloat(rgbMatch[3]));
                        
                        if (count > maxCount) {
                            maxCount = count;
                            dominantColor = [r, g, b];
                        }
                    }
                }
            }
            
            return dominantColor;
        } catch (error) {
            // Fallback to simple method if histogram fails
            console.warn(`Histogram method failed, falling back to simple method: ${error}`);
            return await this.getDominantColor();
        }
    }

    /**
     * Get multiple dominant colors from the image
     * Returns array of RGB values as [[r, g, b], [r, g, b], ...]
     */
    async getDominantColors(colorCount: number = 5): Promise<Array<[number, number, number]>> {
        try {
            let command: string;
            
            if (Image.imageMagickType === 'modern') {
                // Use k-means clustering for ImageMagick 7
                command = `${Image.convertCommand} "${this.filePath}" -resize 500x500 -kmeans ${colorCount} -format "%c" histogram:info:`;
            } else {
                // Use color reduction for legacy ImageMagick
                command = `${Image.convertCommand} "${this.filePath}" -resize 500x500 +dither -colors ${colorCount} -format "%c" histogram:info:`;
            }
            
            const { stdout } = await execAsync(command);
            const lines = stdout.trim().split('\n');
            const colors: Array<{ rgb: [number, number, number], count: number }> = [];
            
            for (const line of lines) {
                if (line.trim()) {
                    const countMatch = line.match(/^\s*(\d+):/);
                    const rgbMatch = line.match(/\(([0-9.]+),([0-9.]+),([0-9.]+)\)/);
                    
                    if (countMatch && rgbMatch) {
                        const count = parseInt(countMatch[1]);
                        const r = Math.round(parseFloat(rgbMatch[1]));
                        const g = Math.round(parseFloat(rgbMatch[2]));
                        const b = Math.round(parseFloat(rgbMatch[3]));
                        
                        colors.push({ rgb: [r, g, b], count });
                    }
                }
            }
            
            // Sort by count (most frequent first) and return RGB values
            return colors
                .sort((a, b) => b.count - a.count)
                .map(color => color.rgb)
                .slice(0, colorCount);
        } catch (error) {
            // Fallback to simple method for single color
            const dominantColor = await this.getDominantColor();
            return [dominantColor];
        }
    }

    getPath(): string {
        return this.filePath;
    }
}