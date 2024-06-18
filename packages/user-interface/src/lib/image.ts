import axios from 'axios';
import * as EXIF from './exif-js/exif';
import { contentType } from 'mime-types';

//
// Loads URL or source data to an image element.
//
export function loadImage(imageSrc: string): Promise<HTMLImageElement> {
    return new Promise<HTMLImageElement>((resolve, reject) => {
        const img = new Image();
        img.onload = () => {
            resolve(img);
        };
        img.src = imageSrc;
    });
}

//
// Loads a blob to a data URL.
//
export function loadBlobToDataURL(blob: Blob): Promise<string> {
    return new Promise<string>((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => {
            resolve(reader.result as string);
        };
        reader.onerror = reject;
        reader.readAsDataURL(blob);
    });
}

//
// Loads a blob to an image element.
//
export async function loadBlobToImage(blob: Blob): Promise<HTMLImageElement> {
    const dataURL = await loadBlobToDataURL(blob);
    return await loadImage(dataURL);
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
export function getImageResolution(image: HTMLImageElement): IResolution {
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
export function resizeImage(image: HTMLImageElement, minSize: number): string { 
    const oc = document.createElement('canvas'); // As long as we don't reference this it will be garbage collected.
    const octx = oc.getContext('2d')!;
    oc.width = image.width;
    oc.height = image.height;
    octx.drawImage(image, 0, 0);

    // Commented out code could be useful.
    if( image.width > image.height) {
        oc.height = minSize;
        oc.width = (image.width / image.height) * minSize;
    } 
    else {
        oc.height = (image.height / image.width) * minSize;
        oc.width = minSize;
    }

    octx.drawImage(oc, 0, 0, oc.width, oc.height);
    octx.drawImage(image, 0, 0, oc.width, oc.height);
    return oc.toDataURL();
}

//
// Resizes an image to outputs a blobg.
//
// https://stackoverflow.com/a/43354901/25868
//
export function resizeImageToBlob(image: HTMLImageElement, minSize: number): Promise<Blob> { 
    return new Promise<Blob>(resolve => {
        const oc = document.createElement('canvas'); // As long as we don't reference this it will be garbage collected.
        const octx = oc.getContext('2d')!;
        oc.width = image.width;
        oc.height = image.height;
        octx.drawImage(image, 0, 0);

        // Commented out code could be useful.
        if( image.width > image.height) {
            oc.height = minSize;
            oc.width = (image.width / image.height) * minSize;
        } 
        else {
            oc.height = (image.height / image.width) * minSize;
            oc.width = minSize;
        }

        octx.drawImage(oc, 0, 0, oc.width, oc.height);
        octx.drawImage(image, 0, 0, oc.width, oc.height);
        oc.toBlob(blob => resolve(blob!));
    });
}

//
// Retreives exif data from the file.
//
// https://github.com/exif-js/exif-js
//
export function getExifData(file: File | Blob): Promise<any> {
    return new Promise((resolve, reject) => {
        EXIF.getData(file as any, function () { // ! Don't change this to an arrow function. It might break the way this works.
            // @ts-ignore. This next line is necessary, but it causes a TypeScript error.
            resolve(EXIF.getAllTags(this));
        });
    });
}

//
// Swaps resolution of the image based on orientation from the exif data.
//
export function getImageDimensions(resolution: IResolution, orientation: number | undefined): IResolution {
    switch (orientation) {
        case 5:
        case 6:
        case 7:
        case 8:
            return {
                width: resolution.height,
                height: resolution.width,
            };
    }

    return resolution;
}

//
// Gets the scale of the image determined from the aspect ratio.
//
function getScaleFromAspectRatio(flipX: boolean, aspectRatio: number | undefined): string | undefined {
    if (aspectRatio !== undefined) {
        if (flipX) {
            return `scaleX(${-1.0 / aspectRatio}) scaleY(${1.0 / aspectRatio})`;
        }
        else {
            return `scale(${1.0 / aspectRatio})`;
        }
    }
    else {
        if (flipX) {
            return `scaleX(-1)`;
        } 
        else {
            return undefined; // No scaling needed.
        }
    }
}

//
// Gets the image transfomrationed based on orientation from the exif data.
// https://sirv.com/help/articles/rotate-photos-to-be-upright/
//
export function getImageTransform(orientation: number | undefined, aspectRatio: number | undefined): string | undefined {
    switch (orientation) {
        case 1:
            return undefined;

        case 2:
            return "scaleX(-1)";

        case 3:
            return "rotate(180deg)";

        case 4:
            return "rotate(180deg) scaleX(-1)";

        case 5: {
            let transform = `rotate(90deg)`;
            let scale = getScaleFromAspectRatio(true, aspectRatio);
            if (scale) {
                transform += ` ` + scale;
            }
            return transform;
        }
        
        case 6: {
            let transform = `rotate(90deg)`;
            let scale = getScaleFromAspectRatio(false, aspectRatio);
            if (scale) {
                transform += ` ` + scale;
            }
            return transform;
        }
        
        case 7: {
            let transform = `rotate(-90deg)`;
            let scale = getScaleFromAspectRatio(true, aspectRatio);
            if (scale) {
                transform += ` ` + scale;
            }
            return transform;
        }
        
        case 8: {
            let transform = `rotate(-90deg)`;
            let scale = getScaleFromAspectRatio(false, aspectRatio);
            if (scale) {
                transform += ` ` + scale;
            }
            return transform;
        }
    }

    return undefined;
}