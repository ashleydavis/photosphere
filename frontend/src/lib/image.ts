//
// Loads a file to a data URL (base64 encoded data).
//
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/Data_URLs
//
export function loadFile(file: File | Blob): Promise<string> { 
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.addEventListener('error', () => {
            reject(new Error(`Error reading file.`));
        });

        reader.addEventListener('load', evt => {
            resolve(evt.target!.result as string)
        });
        
        reader.readAsDataURL(file);
    });
}

//
// Loads URL or source data to an image element.
//
export function loadImage(imageSrc: string): Promise<HTMLImageElement> {
    return new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => {
            resolve(img);
        };
        img.src = imageSrc;
    });
}

//
// Represents the resolution of the image or video.
//
export interface IResolution {
    //
    // The width of the image or video.
    //
    width: number;

    //
    // The height of the image or video.
    //
    height: number;
}

//
// Gets the size of an image element.
//
export async function getImageResolution(imageSrc: string): Promise<IResolution> {
    const image = await loadImage(imageSrc);
    return {
        width: image.width,
        height: image.height,
    };
}
