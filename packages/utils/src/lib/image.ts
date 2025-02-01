
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
}

//
// Gets the transformation for an image.
//
export function getImageTransformation(asset: any): IImageTransformation | undefined {
  let orientation = 1;
  if (asset.properties?.exif?.Orientation) {
      orientation = asset.properties.exif.Orientation?.[0];
  }
  else if (asset.properties?.metadata?.Orientation) {
      orientation = asset.properties.metadata.Orientation?.[0];
  }

  console.log(`Asset ${asset._id} orientation: ${orientation}`);

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
          };
      }

      case 6: {
          return {
              rotate: 90,
          };
      }

      case 7: {
          return {
              flipX: true,
              rotate: 90, // Clockwise.
          };
      }

      case 8: {
          return {
              rotate: 270, // Clockwise.
          };
      }

      default: {
          throw new Error(`Unsupported orientation: ${orientation}`);
      }
  }
}
