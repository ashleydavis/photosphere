import { Readable } from "node:stream";
import { IFileInfo } from "storage";

const sharp = require('sharp');
const ffmpeg = require('fluent-ffmpeg');
const ffmpegPaths = require('ffmpeg-ffprobe-static');
ffmpeg.setFfmpegPath(ffmpegPaths.ffmpegPath);
ffmpeg.setFfprobePath(ffmpegPaths.ffprobePath);

//
// Validates that a file is good before allowing it to be added to the merkle tree.
//
export async function validateFile(filePath: string, fileInfo: IFileInfo, contentType: string, openStream: () => Readable): Promise<boolean> {

    if (contentType === "image/psd") {
        // Not sure how to validate PSD files just yet.
        return true;
    }

    if (contentType.startsWith("image")) {
        const imageStream = sharp();
        openStream().pipe(imageStream);
        const metadata = await imageStream.metadata()
        if (typeof (metadata.width) === 'number' && typeof (metadata.height) === 'number') {
            // console.log(`Image ${filePath} (${fileInfo.contentType}) has dimensions ${metadata.width}x${metadata.height}`);
            return true;
        }
        else {
            console.error(`Invalid image ${filePath} (${contentType})`);
            return false;
        }
    }
    else if (contentType.startsWith("video")) {
        const metadata = await getVideoMetadata(openStream());
        if (typeof (metadata.width) === 'number' && typeof (metadata.height) === 'number') {
            // console.log(`Video ${filePath} (${fileInfo.contentType}) has dimensions ${metadata.width}x${metadata.height}`);
            return true;
        }
        else {
            console.error(`Invalid video ${filePath} (${contentType})`);
            return false;
        }
    }

    return true;
}

//
// Gets the metadata data for a video.
//
export function getVideoMetadata(inputStream: Readable): Promise<{ width: number, height: number }> {
  return new Promise((resolve, reject) => {
      ffmpeg.ffprobe(inputStream, (err: any, metadata: any) => {
          if (err) {
              reject(err);
          }
          else {
              const videoStream = metadata.streams.find((stream: any) => stream.codec_type === 'video');
              if (videoStream) {
                  resolve({
                      width: videoStream.width,
                      height: videoStream.height,
                  });
              }
              else {
                  reject(new Error('No video stream found'));
              }
          }
      });
  });
}
