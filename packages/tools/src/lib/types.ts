export interface Dimensions {
    width: number;
    height: number;
}

export interface AssetInfo {
    // Basic identification
    type: 'image' | 'video';
    format: string;           // e.g., 'jpeg', 'png', 'mp4', 'mov'
    mimeType: string;         // e.g., 'image/jpeg', 'video/mp4'
    
    // File information
    filePath: string;
    fileSize: number;         // in bytes
    
    // Visual properties
    dimensions: Dimensions;
    
    // Optional properties (may be null for images or videos)
    duration?: number;        // in seconds (null for images)
    fps?: number;            // frames per second (null for images)
    bitrate?: number;        // in bits/sec (mainly for videos)
    hasAudio?: boolean;      // for videos
    
    // Common metadata
    colorSpace?: string;
    createdAt?: Date;
    modifiedAt?: Date;
    
    // Raw metadata (EXIF for images, format tags for videos)
    metadata?: Record<string, any>;
}

export interface ResizeOptions {
    width?: number;
    height?: number;
    quality?: number;
    format?: 'jpeg' | 'jpg' | 'png' | 'webp' | 'gif' | 'bmp' | 'tiff';
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