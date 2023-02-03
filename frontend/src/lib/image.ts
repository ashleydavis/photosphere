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

//
// Resizes an image.
//
// https://stackoverflow.com/a/43354901/25868
//
export function resizeImage(imageData: string, maxSize: number): Promise<string> {
    return new Promise(resolve => {
        const img = new Image();
        img.onload = () => {
            const oc = document.createElement('canvas'); // As long as we don't reference this it will be garbage collected.
            const octx = oc.getContext('2d')!;
            oc.width = img.width;
            oc.height = img.height;
            octx.drawImage(img, 0, 0);

            // Commented out code could be useful.
            if( img.width > img.height) {
                oc.height = (img.height / img.width) * maxSize;
                oc.width = maxSize;
            } 
            else {
                oc.width = (img.width / img.height) * maxSize;
                oc.height = maxSize;
            }

            octx.drawImage(oc, 0, 0, oc.width, oc.height);
            octx.drawImage(img, 0, 0, oc.width, oc.height);
            resolve(oc.toDataURL());
        };
        img.src = imageData;
    });
}