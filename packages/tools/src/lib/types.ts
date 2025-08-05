export interface Dimensions {
    width: number;
    height: number;
}

export interface AssetInfo {    
    // File information
    filePath: string;

    // Visual properties
    dimensions: Dimensions;
    
    // Optional properties (may be null for images or videos)
    duration?: number;        // in seconds (null for images)
    fps?: number;            // frames per second (null for images)
    bitrate?: number;        // in bits/sec (mainly for videos)
    hasAudio?: boolean;      // for videos
    
    // Common metadata
    createdAt?: Date;
    
    // Raw metadata (EXIF for images, format tags for videos)
    metadata?: Record<string, any>;
}

export interface ResizeOptions {
    width: number;
    height: number;
    quality: number;
    format: 'jpeg' | 'jpg' | 'png' | 'webp' | 'gif' | 'bmp' | 'tiff';
    ext: string;
    maintainAspectRatio?: boolean;
}

export interface ImageMagickConfig {
    convertPath?: string;
    identifyPath?: string;
}

export interface VideoConfig {
    ffprobePath?: string;
    ffmpegPath?: string;
}