import { IAsset } from "defs";
import { isArray } from "lodash";

//
// Options for transforming an image.
//
export interface IImageTransformation {
    // 
    // The orientation of the image.
    //
    rotate?: number;

    //
    // True if the image should be flipped horizontally.
    //  
    flipX?: boolean;

    //
    // Changes the orientation of the image.
    //
    changeOrientation?: boolean;
}

//
// Gets the transformation for an image.
//
export function getImageTransformation(exif: any): IImageTransformation | undefined {
    let orientation = 1;
    if (exif?.Orientation) {
        if (isArray(exif.Orientation)) {
            orientation = exif.Orientation?.[0];
        }
        else {
            orientation = exif.Orientation
        }
    }

    switch (orientation) {
        case 1:
            return undefined; // No transform needed.

        case 2:
            return {
                flipX: true,
            };

        case 3:
            return {
                rotate: 180, // Clockwise.
            };

        case 4:
            return {
                flipX: true,
                rotate: 180, // Clockwise.
            };

        case 5: {
            return {
                flipX: true,
                rotate: 270, // Clockwise.
                changeOrientation: true,                
            };
        }

        case 6: {
            return {
                rotate: 90,
                changeOrientation: true,
            };
        }

        case 7: {
            return {
                flipX: true,
                rotate: 90, // Clockwise.
                changeOrientation: true,
            };
        }

        case 8: {
            return {
                rotate: 270, // Clockwise.
                changeOrientation: true,
            };
        }

        default: {
            throw new Error(`Unsupported orientation: ${orientation}`);
        }
    }
}

//
// Gets the transformation for a video.
//
export function getVideoTransformation(metadata: any): IImageTransformation | undefined {

    let rotation: string | undefined = undefined;

    for (const stream of metadata.streams) {
        if (stream.rotation) {
            rotation = stream.rotation.toString();
            break;
        }
    }

    if (!rotation) {
        return undefined;
    }

    const imageTransformation: IImageTransformation = {
        rotate: parseFloat(rotation!),
        changeOrientation: rotation === "-90" || rotation === "90" || rotation === "270" || rotation === "-270",
    };
    return imageTransformation;
}