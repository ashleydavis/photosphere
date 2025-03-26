import { IFileInfo, IStorage } from "./lib/storage";
import fs from "fs";

export * from "./lib/storage";
export * from "./lib/cloud-storage";
export * from "./lib/file-storage";
export * from "./lib/encrypted-storage";
export * from "./lib/storage-prefix-wrapper";
export * from "./lib/bson-database/database";
export * from "./lib/bson-database/collection";
export * from "./lib/storage-factory";

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
