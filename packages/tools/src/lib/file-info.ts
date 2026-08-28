import { Image } from './image';
import { Video } from './video';
import { AssetInfo } from './types';

/**
 * Gets file information for an image or video file based on content type
 * @param filePath Path to the file to analyze
 * @param contentType MIME type of the file (e.g., 'image/jpeg', 'video/mp4')
 * @returns AssetInfo for images/videos, or undefined for other file types
 */
export async function getFileInfo(filePath: string, contentType: string): Promise<AssetInfo | undefined> {
    if (contentType.startsWith('image/')) {
        try {
            const image = new Image(filePath);
            return await image.getInfo();
        } catch (error) {
            // The stack goes in because the message alone does not say where the failure came from,
            // and one of these (a QuickJS stack overflow on a phone part way through a large import)
            // could not be placed without it.
            throw new Error(`Failed to get image info for ${filePath}: ${error}\n${(error as Error)?.stack ?? ""}`);
        }
    } else if (contentType.startsWith('video/')) {
        try {
            const video = new Video(filePath);
            return await video.getInfo();
        } catch (error) {
            throw new Error(`Failed to get video info for ${filePath}: ${error}\n${(error as Error)?.stack ?? ""}`);
        }
    }
    
    // Return undefined for unsupported file types
    return undefined;
}