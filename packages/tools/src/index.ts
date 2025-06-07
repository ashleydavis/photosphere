// Export main classes
export { Image } from './lib/image';
export { Video } from './lib/video';

// Export types
export type {
    AssetInfo,
    Dimensions,
    ResizeOptions,
    ImageMagickConfig,
    VideoConfig
} from './lib/types';

// Export tool management functions
export { 
    verifyTools, 
    ensureToolsAvailable,
    type ToolStatus,
    type ToolsStatus 
} from './lib/tool-verification';

export { 
    promptAndDownloadTools,
    getToolsDirectory 
} from './lib/tool-downloader';