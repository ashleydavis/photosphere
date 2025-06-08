import { Image } from './image';
import { Video } from './video';

export interface ToolStatus {
    available: boolean;
    version?: string;
    error?: string;
}

export interface ToolsStatus {
    magick: ToolStatus;
    ffprobe: ToolStatus;
    ffmpeg: ToolStatus;
    allAvailable: boolean;
    missingTools: string[];
}

/**
 * Check the availability of all required tools
 */
export async function verifyTools(): Promise<ToolsStatus> {
    const [magickStatus, ffprobeStatus, ffmpegStatus] = await Promise.all([
        Image.verifyImageMagick(),
        Video.verifyFfprobe(),
        Video.verifyFfmpeg()
    ]);

    const missingTools: string[] = [];
    
    if (!magickStatus.available) {
        missingTools.push('ImageMagick');
    }
    if (!ffprobeStatus.available) {
        missingTools.push('ffprobe');
    }
    if (!ffmpegStatus.available) {
        missingTools.push('ffmpeg');
    }

    return {
        magick: magickStatus,
        ffprobe: ffprobeStatus,
        ffmpeg: ffmpegStatus,
        allAvailable: missingTools.length === 0,
        missingTools
    };
}

/**
 * Check if all required tools are available
 */
export async function ensureToolsAvailable(options?: {
    promptForInstall?: boolean;
    silent?: boolean;
}): Promise<boolean> {
    const { silent = false } = options || {};
    
    const toolsStatus = await verifyTools();
    
    if (toolsStatus.allAvailable) {
        if (!silent) {
            console.log('✓ All required tools are available:');
            if (toolsStatus.magick.version) {
                console.log(`  • ImageMagick v${toolsStatus.magick.version}`);
            }
            if (toolsStatus.ffprobe.version) {
                console.log(`  • ffprobe v${toolsStatus.ffprobe.version}`);
            }
            if (toolsStatus.ffmpeg.version) {
                console.log(`  • ffmpeg v${toolsStatus.ffmpeg.version}`);
            }
        }
        return true;
    }

    return false;
}