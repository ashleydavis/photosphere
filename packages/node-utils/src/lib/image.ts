import sharp from "sharp";

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
// Gets the resolution of an image.
//
export async function getImageResolution(filePath: string, fileData: Buffer): Promise<IResolution> {
  //
  // Get image resolution.
  //
  const fullImage = sharp(fileData);
  const { width, height } = await fullImage.metadata();
  if (width === undefined || height === undefined) {
      throw new Error(`Failed to get image resolution for ${filePath}`);
  }

  return { width, height };
}

//
// Resize an image.
//
export async function resizeImage(inputData: Buffer, resolution: { width: number, height: number }, minSize: number, quality: number = 90): Promise<Buffer> {

  let width: number;
  let height: number;

  if (resolution.width > resolution.height) {
      height = minSize;
      width = Math.trunc((resolution.width / resolution.height) * minSize);
  } 
  else {
      height = Math.trunc((resolution.height / resolution.width) * minSize);
      width = minSize;
  }

  return await sharp(inputData)
      .resize(width, height, {
          fit: sharp.fit.fill,
      })
      .jpeg({
        quality: 75,
      })
      .toBuffer();
}