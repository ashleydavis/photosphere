// Export main classes
export { Image } from './lib/image';
export { Video } from './lib/video';

// Export unified file info function
export { getFileInfo } from './lib/file-info';

// Export types
export type {
    AssetInfo,
    Dimensions,
    ResizeOptions,
    ImageMagickConfig,
    VideoConfig
} from './lib/types';

export { 
    promptAndDownloadTools,
    getToolsDirectory 
} from './lib/tool-downloader';