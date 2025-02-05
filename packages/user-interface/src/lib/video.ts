//
// Loads a blob to a video element.
//
// NOTE: The video is automatically rotated to match the orientation in exif.
// 
export function loadVideo(blob: Blob): Promise<HTMLVideoElement> {
    return new Promise<HTMLVideoElement>((resolve, reject) => {
        const video = document.createElement('video');
        video.muted = true;
        video.autoplay = true;
        video.onloadeddata = () => {
            resolve(video);
        };
        video.onerror = (err: any) => {
            if (err.currentTarget?.error) {
                reject(err.currentTarget.error);
            }
            else {                
                reject(err);
            }
        };
        video.src = URL.createObjectURL(blob);
        video.load();
    });
}

//
// Unloads a video.
// This must be done to prevent memory leaks.
//
export function unloadVideo(video: HTMLVideoElement) {
    const objectUrl = video.src;
    video.src = "";
    URL.revokeObjectURL(objectUrl);
}

//
// Captures an image from the video.
// Returns a data URL.
//
export function captureVideoThumbnail(video: HTMLVideoElement, minSize: number): { dataUrl: string, contentType: string } {
    const captureCanvas = document.createElement('canvas');
    captureCanvas.width = video.videoWidth;
    captureCanvas.height = video.videoHeight;
    const captureContext = captureCanvas.getContext('2d')
    if (!captureContext) {
        throw new Error("Failed to create 2d context.");
    }

    //
    // Capture full res image from video.
    //
    captureContext.drawImage(video, 0, 0, captureCanvas.width, captureCanvas.height);

    const thumbnailCanvas = document.createElement('canvas');
    if (video.videoWidth > video.videoHeight) {
        thumbnailCanvas.height = minSize;
        thumbnailCanvas.width = (video.videoWidth / video.videoHeight) * minSize;
    } 
    else {
        thumbnailCanvas.height = (video.videoHeight / video.videoWidth) * minSize;
        thumbnailCanvas.width = minSize;
    }

    const thumbnailContext = thumbnailCanvas.getContext('2d');
    if (!thumbnailContext) {
        throw new Error("Failed to create 2d context for thumbnail.");
    }

    //
    // Draw the resized image.
    //
    thumbnailContext.drawImage(captureCanvas, 0, 0, captureCanvas.width, captureCanvas.height, 0, 0, thumbnailCanvas.width, thumbnailCanvas.height);

    const contentType = "image/jpeg";
    const dataUrl = thumbnailCanvas.toDataURL(contentType);
    return { dataUrl, contentType };
}