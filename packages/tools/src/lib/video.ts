import { exec } from 'child_process';
import { promisify } from 'util';
import { existsSync, statSync } from 'fs';
import { join, dirname } from 'path';
import { homedir, platform } from 'os';
import { AssetInfo, Dimensions, VideoConfig } from './types';

const execAsync = promisify(exec);

export class Video {
    private filePath: string;
    private _info: AssetInfo | null = null;
    private static ffprobeCommand: string = 'ffprobe';
    private static ffmpegCommand: string = 'ffmpeg';
    private static isInitialized: boolean = false;

    constructor(filePath: string) {
        if (!existsSync(filePath)) {
            throw new Error(`File not found: ${filePath}`);
        }
        this.filePath = filePath;
        
        // Initialize ffmpeg/ffprobe commands on first use
        if (!Video.isInitialized) {
            Video.initializeCommands();
        }
    }

    /**
     * Configure custom paths for ffmpeg/ffprobe binaries
     */
    static configure(config: VideoConfig) {
        if (config.ffprobePath) {
            Video.ffprobeCommand = config.ffprobePath;
        }
        if (config.ffmpegPath) {
            Video.ffmpegCommand = config.ffmpegPath;
        }
        Video.isInitialized = true;
    }

    /**
     * Initialize ffmpeg/ffprobe commands by checking multiple locations
     */
    private static async initializeCommands() {
        if (Video.isInitialized) return;

        // Get the directory of the current executable
        const currentDir = process.cwd();
        const execDir = dirname(process.execPath);
        const toolsDir = join(homedir(), '.photosphere', 'tools');

        // Possible paths to check for ffprobe binary
        // PRIORITY ORDER: Local directories first, then system PATH
        const possiblePaths = [
            // 1. Photosphere tools directory (highest priority)
            { ffprobe: join(toolsDir, 'ffprobe'), ffmpeg: join(toolsDir, 'ffmpeg') },
            { ffprobe: join(toolsDir, 'ffprobe.exe'), ffmpeg: join(toolsDir, 'ffmpeg.exe') },
            
            // 2. Current working directory
            { ffprobe: join(currentDir, 'ffprobe'), ffmpeg: join(currentDir, 'ffmpeg') },
            { ffprobe: join(currentDir, 'ffprobe.exe'), ffmpeg: join(currentDir, 'ffmpeg.exe') },
            
            // 3. Directory of the executable (for bundled apps)
            { ffprobe: join(execDir, 'ffprobe'), ffmpeg: join(execDir, 'ffmpeg') },
            { ffprobe: join(execDir, 'ffprobe.exe'), ffmpeg: join(execDir, 'ffmpeg.exe') },
            
            // 4. System PATH (lowest priority)
            { ffprobe: 'ffprobe', ffmpeg: 'ffmpeg' },
        ];

        // Try to find working ffmpeg/ffprobe commands
        for (const paths of possiblePaths) {
            try {
                // Test ffprobe command
                const { stdout } = await execAsync(`"${paths.ffprobe}" -version`);
                
                // If we get here, ffprobe works
                Video.ffprobeCommand = `"${paths.ffprobe}"`;
                Video.ffmpegCommand = `"${paths.ffmpeg}"`;
                Video.isInitialized = true;
                
                // Get version info
                const versionMatch = stdout.match(/ffprobe version ([\d.-]+)/);
                const version = versionMatch ? versionMatch[1] : 'unknown';
                
                const isLocal = paths.ffprobe.startsWith(currentDir) || paths.ffprobe.startsWith(execDir) || paths.ffprobe.startsWith(toolsDir);
                console.log(`Using ${isLocal ? 'local' : 'system'} ffprobe: ${paths.ffprobe}`);
                console.log(`ffprobe version: ${version}`);
                return;
            } catch {
                // Try next path
                continue;
            }
        }

        // If we get here, we couldn't find ffmpeg/ffprobe
        console.warn('ffprobe not found. Please install ffmpeg.');
        Video.isInitialized = true;
    }

    /**
     * Verify that ffprobe is available
     */
    static async verifyFfprobe(): Promise<{ available: boolean; version?: string; error?: string }> {
        try {
            // Initialize if not already done
            if (!Video.isInitialized) {
                await Video.initializeCommands();
            }
            
            const { stdout } = await execAsync(`${Video.ffprobeCommand} -version`);
            
            const versionMatch = stdout.match(/ffprobe version ([\d.-]+)/);
            return {
                available: true,
                version: versionMatch ? versionMatch[1] : 'unknown'
            };
        } catch (error) {
            return {
                available: false,
                error: `ffprobe not found. Make sure ffmpeg is installed.`
            };
        }
    }

    /**
     * Verify that ffmpeg is available
     */
    static async verifyFfmpeg(): Promise<{ available: boolean; version?: string; error?: string }> {
        try {
            // Initialize if not already done
            if (!Video.isInitialized) {
                await Video.initializeCommands();
            }
            
            const { stdout } = await execAsync(`${Video.ffmpegCommand} -version`);
            
            const versionMatch = stdout.match(/ffmpeg version ([\d.-]+)/);
            return {
                available: true,
                version: versionMatch ? versionMatch[1] : 'unknown'
            };
        } catch (error) {
            return {
                available: false,
                error: `ffmpeg not found. Make sure ffmpeg is installed.`
            };
        }
    }

    private async getVideoInfo(): Promise<AssetInfo> {
        if (this._info) {
            return this._info;
        }

        try {
            // Get file stats
            const stats = statSync(this.filePath);
            
            // Run ffprobe to get video information in JSON format
            const { stdout } = await execAsync(
                `${Video.ffprobeCommand} -v quiet -print_format json -show_format -show_streams "${this.filePath}"`
            );
            
            const probeData = JSON.parse(stdout);
            const format = probeData.format;
            const videoStream = probeData.streams.find((s: any) => s.codec_type === 'video');
            const audioStream = probeData.streams.find((s: any) => s.codec_type === 'audio');
            
            if (!videoStream) {
                throw new Error('No video stream found in file');
            }

            // Extract format name
            const formatName = format.format_name.split(',')[0]; // e.g., 'mov,mp4,m4a,3gp,3g2,mj2' -> 'mov'
            
            // Determine MIME type
            const mimeTypes: Record<string, string> = {
                'mp4': 'video/mp4',
                'mov': 'video/quicktime',
                'avi': 'video/x-msvideo',
                'mkv': 'video/x-matroska',
                'webm': 'video/webm',
                'flv': 'video/x-flv',
                'wmv': 'video/x-ms-wmv',
                'mpg': 'video/mpeg',
                'mpeg': 'video/mpeg',
                'm4v': 'video/mp4',
                '3gp': 'video/3gpp'
            };

            // Parse creation time if available
            let createdAt: Date | undefined;
            if (format.tags?.creation_time) {
                createdAt = new Date(format.tags.creation_time);
            }

            // Parse framerate
            let fps: number | undefined;
            if (videoStream.r_frame_rate) {
                const [num, den] = videoStream.r_frame_rate.split('/').map(Number);
                fps = num / den;
            }

            this._info = {
                type: 'video',
                format: formatName,
                mimeType: mimeTypes[formatName] || `video/${formatName}`,
                
                filePath: this.filePath,
                fileSize: parseInt(format.size) || stats.size,
                
                dimensions: {
                    width: videoStream.width,
                    height: videoStream.height
                },
                
                duration: parseFloat(format.duration),
                fps,
                bitrate: parseInt(format.bit_rate),
                hasAudio: !!audioStream,
                
                colorSpace: videoStream.color_space,
                createdAt,
                modifiedAt: stats.mtime,
                
                metadata: {
                    ...format.tags,
                    videoCodec: videoStream.codec_name,
                    audioCodec: audioStream?.codec_name,
                    pixelFormat: videoStream.pix_fmt
                }
            };

            return this._info;
        } catch (error) {
            throw new Error(`Failed to get video info: ${error}`);
        }
    }

    async getInfo(): Promise<AssetInfo> {
        return await this.getVideoInfo();
    }

    async getDimensions(): Promise<Dimensions> {
        const info = await this.getVideoInfo();
        return info.dimensions;
    }

    async getMimeType(): Promise<string> {
        const info = await this.getVideoInfo();
        return info.mimeType;
    }

    async getDuration(): Promise<number> {
        const info = await this.getVideoInfo();
        return info.duration || 0;
    }

    /**
     * Extract a screenshot/thumbnail from the video at a specific time
     */
    async extractScreenshot(outputPath: string, timeInSeconds: number = 1, options?: {
        width?: number;
        height?: number;
        quality?: number;
    }): Promise<string> {
        const { width, height, quality = 85 } = options || {};
        
        let command = `${Video.ffmpegCommand} -i "${this.filePath}" -ss ${timeInSeconds} -vframes 1`;
        
        // Add scaling if specified
        if (width || height) {
            const scale = width && height ? `${width}:${height}` : 
                         width ? `${width}:-1` : 
                         `-1:${height}`;
            command += ` -vf scale=${scale}`;
        }
        
        // Add quality
        command += ` -q:v ${Math.round((100 - quality) / 10)}`;
        
        // Force overwrite and specify output
        command += ` -y "${outputPath}"`;
        
        try {
            await execAsync(command);
            return outputPath;
        } catch (error) {
            throw new Error(`Failed to extract screenshot: ${error}`);
        }
    }

    getPath(): string {
        return this.filePath;
    }
}