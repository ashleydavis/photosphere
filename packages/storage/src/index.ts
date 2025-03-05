import { IFileInfo, IStorage } from "./lib/storage";
import fs from "fs";

export * from "./lib/storage";
export * from "./lib/cloud-storage";
export * from "./lib/file-storage";
export * from "./lib/encrypted-storage";

export interface IAssetMetadata {
  //
  // The ID of the asset.
  //
  _id: string;

  //
  // The ID of the set that the asset belongs to.
  //
  setId: string;
}

//
// Streams an asset from source to destination storage.
//
export async function streamAsset(sourceStorage: IStorage, destStorage: IStorage, metadata: IAssetMetadata, assetType: string): Promise<void> {
  const fileInfo = await sourceStorage.info(`collections/${metadata.setId}/${assetType}`, metadata._id);
  if (!fileInfo) {
      throw new Error(`Document ${metadata._id} does not have file info:\r\n${JSON.stringify(metadata)}`);
  }

  await destStorage.writeStream(`collections/${metadata.setId}/${assetType}`, metadata._id, fileInfo.contentType,
      sourceStorage.readStream(`collections/${metadata.setId}/${assetType}`, metadata._id)
  );

  // console.log(`Wrote asset for ${assetType}/${metadata._id}.`);
}

//
// Streams an asset from source to destination storage.
// Retries on failure.
//
export async function streamAssetWithRetry(sourceStorage: IStorage, destStorage: IStorage, metadata: IAssetMetadata, assetType: string): Promise<void> {
  let lastErr = undefined;
  let retries = 3;
  while (retries > 0) {
      try {
          await streamAsset(sourceStorage, destStorage, metadata, assetType);
          return;
      }
      catch (err) {
          lastErr = err;
          console.error(`Failed to download asset ${assetType}/${metadata._id}. Retries left: ${retries}.`);
          console.error(err);
          retries--;
      }
  }

  throw lastErr;
}

//
// Gets the info about an asset.
// Retries on failure.
//
export async function getAssetInfoWithRetry(storage: IStorage, assetId: string, setId: string, assetType: string): Promise<IFileInfo | undefined> {
  let lastErr = undefined;
  let retries = 3;
  while (retries > 0) {
      try {
          return await storage.info(`collections/${setId}/${assetType}`, assetId);
      }
      catch (err) {
          lastErr = err;
          console.error(`Failed to get asset info ${assetType}/${assetId}. Retries left: ${retries}.`);
          console.error(err);
          retries--;
      }
  }

  throw lastErr;
}

//
// Reads an asset from source storage.
// Retries on failure.
//
export async function readAssetWithRetry(sourceStorage: IStorage, assetId: string, setId: string, assetType: string): Promise<Buffer | undefined> {
  let lastErr = undefined;
  let retries = 3;
  while (retries > 0) {
      try {
          return await sourceStorage.read(`collections/${setId}/${assetType}`, assetId);
      }
      catch (err) {
          lastErr = err;
          console.error(`Failed to download asset ${assetType}/${assetId}. Retries left: ${retries}.`);
          console.error(err);
          retries--;
      }
  }

  throw lastErr;
}

//
// Writes an asset with retries.
//
export async function writeAssetWithRetry(storage: IStorage, assetId: string, setId: string, assetType: string, contentType: string, data: Buffer): Promise<void> {
  let lastErr = undefined;
  let retries = 3;
  while (retries > 0) {
      try {
          await storage.write(`collections/${setId}/${assetType}`, assetId, contentType, data);
          return;
      }
      catch (err) {
          lastErr = err;
          console.error(`Failed to write asset ${assetType}/${assetId}. Retries left: ${retries}.`);
          console.error(err);
          retries--;
      }
  }

  throw lastErr;
}

//
// Deletes an asset with retries.
//
export async function deleteAssetWithRetry(storage: IStorage, assetId: string, setId: string, assetType: string): Promise<void> {
    let lastErr = undefined;
    let retries = 3;
    while (retries > 0) {
        try {
            await storage.delete(`collections/${setId}/${assetType}`, assetId);
            return;
        }
        catch (err) {
            lastErr = err;
            console.error(`Failed to delete asset ${assetType}/${assetId}. Retries left: ${retries}.`);
            console.error(err);
            retries--;
        }
    }
    
    throw lastErr;
}

//
// Uploads a file stream with retries.
//
export async function uploadFileStreamWithRetry(filePath: string, storage: IStorage, assetId: string, setId: string, assetType: string, contentType: string): Promise<void> {
    let lastErr = undefined;
    let retries = 3;
    while (retries > 0) {
        try {
            const fileStream = fs.createReadStream(filePath);
            await storage.writeStream(`collections/${setId}/${assetType}`, assetId, contentType, fileStream);            
        }
        catch (err) {
            lastErr = err;
            console.error(`Failed to upload file ${filePath} to ${assetType}. Retries left: ${retries}.`);
            console.error(err);
            retries--;
        }
    }

    throw lastErr;
}