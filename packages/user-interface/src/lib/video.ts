//
// Loads a file to a video element.
// 
export function loadVideo(fileData: Blob): Promise<HTMLVideoElement> {
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
        video.src = URL.createObjectURL(fileData);
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
export function captureVideoImage(video: HTMLVideoElement): { thumbnailDataUrl: string, contentType: string } {
    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    const context = canvas.getContext('2d')
    if (!context) {
        throw new Error("Failed to create 2d context.");
    }
    context.drawImage(video, 0, 0, canvas.width, canvas.height);
    const contentType = "image/png";
    const thumbnailDataUrl = canvas.toDataURL(contentType);
    return { thumbnailDataUrl, contentType };
}