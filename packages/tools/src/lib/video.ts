import fs from 'fs-extra';
import { AssetInfo, Dimensions, VideoConfig } from './types';
import { log } from 'utils';
import { exec } from 'node-utils';

export class Video {
    private filePath: string;
    private _info: AssetInfo | null = null;
    private static ffprobeCommand: string = 'ffprobe';
    private static ffmpegCommand: string = 'ffmpeg';
    private static isInitialized: boolean = false;

    constructor(filePath: string) {
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
     * Initialize ffmpeg/ffprobe commands by checking system PATH
     */
    private static async initializeCommands() {
        if (Video.isInitialized) return;

        try {
            // Test if ffprobe command is available in system PATH
            const { stdout } = await exec('ffprobe -version');
            
            // If we get here, ffprobe works (and ffmpeg should too)
            Video.ffprobeCommand = 'ffprobe';
            Video.ffmpegCommand = 'ffmpeg';
            Video.isInitialized = true;
            
            // Get version info
            const versionMatch = stdout.match(/ffprobe version ([\d.-]+)/);
            const version = versionMatch ? versionMatch[1] : 'unknown';
            
            log.verbose(`Using system ffprobe: ffprobe`);
            log.verbose(`ffprobe version: ${version}`);
        } catch {
            // ffprobe not found in PATH
            Video.isInitialized = true;
        }
    }

    /**
     * Verify that ffprobe is available
     */
    static async verifyFfprobe(): Promise<{ available: boolean; version?: string; error?: string }> {
        try {
            const { stdout } = await exec('ffprobe -version');
            
            const versionMatch = stdout.match(/ffprobe version (\S+)/);
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
            const { stdout } = await exec('ffmpeg -version');
            
            const versionMatch = stdout.match(/ffmpeg version (\S+)/);
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

        if (!await fs.exists(this.filePath)) {
            throw new Error(`File not found: ${this.filePath}`);
        }
        
        try {

            // Run ffprobe to get video information in JSON format
            const { stdout } = await exec(
                `${Video.ffprobeCommand} -v quiet -print_format json -show_format -show_streams "${this.filePath}"`
            );
            
            const probeData = JSON.parse(stdout);
            const format = probeData.format;
            const videoStream = probeData.streams.find((s: any) => s.codec_type === 'video');
            const audioStream = probeData.streams.find((s: any) => s.codec_type === 'audio');            
            if (!videoStream) {
                throw new Error('No video stream found in file');
            }

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
                filePath: this.filePath,
                
                dimensions: {
                    width: videoStream.width,
                    height: videoStream.height
                },
                
                duration: parseFloat(format.duration),
                fps,
                bitrate: parseInt(format.bit_rate),
                hasAudio: !!audioStream,
                
                createdAt,
                
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
        if (!await fs.exists(this.filePath)) {
            throw new Error(`File not found: ${this.filePath}`);
        }

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
            await exec(command);
            return outputPath;
        } catch (error) {
            throw new Error(`Failed to extract screenshot: ${error}`);
        }
    }

    getPath(): string {
        return this.filePath;
    }
}