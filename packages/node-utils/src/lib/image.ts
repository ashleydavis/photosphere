import { Image } from "tools";
import { IImageTransformation } from "utils";
import { writeFileSync, readFileSync, unlinkSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

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
export async function getImageResolution(fileData: Buffer): Promise<IResolution> {
  // Create a temporary file from the buffer
  const tempPath = join(tmpdir(), `temp_image_${Date.now()}_${Math.random().toString(36).substring(2)}.jpg`);
  writeFileSync(tempPath, fileData);
  
  try {
    const image = new Image(tempPath);
    const dimensions = await image.getDimensions();
    return dimensions;
  } finally {
    unlinkSync(tempPath);
  }
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

  // Create temporary files
  const inputPath = join(tmpdir(), `temp_input_${Date.now()}_${Math.random().toString(36).substring(2)}.jpg`);
  const outputPath = join(tmpdir(), `temp_output_${Date.now()}_${Math.random().toString(36).substring(2)}.jpg`);
  
  writeFileSync(inputPath, inputData);
  
  try {
    const image = new Image(inputPath);
    await image.resize({ width, height, quality: Math.round(quality), format: 'jpeg' }, outputPath);
    
    const resultBuffer = readFileSync(outputPath);
    return resultBuffer;
  } finally {
    unlinkSync(inputPath);
    try { unlinkSync(outputPath); } catch {}
  }
}

//
// Transforms an image.
//
export async function transformImage(inputData: Buffer, options: IImageTransformation): Promise<Buffer> {
  // Create temporary files
  const inputPath = join(tmpdir(), `temp_transform_input_${Date.now()}_${Math.random().toString(36).substring(2)}.jpg`);
  const outputPath = join(tmpdir(), `temp_transform_output_${Date.now()}_${Math.random().toString(36).substring(2)}.jpg`);
  
  writeFileSync(inputPath, inputData);
  
  try {
    const image = new Image(inputPath);
    
    // Build ImageMagick command for transformations
    let transformCommand = '';
    
    if (options.flipX) {
      transformCommand += ' -flop';
    }
    
    if (options.rotate) {
      transformCommand += ` -rotate ${options.rotate}`;
    }
    
    // If we have transformations to apply, use ImageMagick convert directly
    if (transformCommand) {
      const { exec } = await import('child_process');
      const { promisify } = await import('util');
      const execAsync = promisify(exec);
      
      const command = `magick convert "${inputPath}"${transformCommand} "${outputPath}"`;
      await execAsync(command);
      
      const resultBuffer = readFileSync(outputPath);
      return resultBuffer;
    } else {
      // No transformations needed, just return the original data
      return inputData;
    }
  } finally {
    unlinkSync(inputPath);
    try { unlinkSync(outputPath); } catch {}
  }
}
