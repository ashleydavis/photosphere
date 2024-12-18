import { IStorage } from "./lib/storage";

export * from "./lib/storage";
export * from "./lib/cloud-storage";
export * from "./lib/file-storage";

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
