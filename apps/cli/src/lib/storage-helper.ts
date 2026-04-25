import { createStorage, IS3Credentials, ICreateStorageResult } from "storage";
import type { IStorageOptions } from "storage";
import { getDefaultS3Config } from "./init-cmd";

//
// Returns S3 credentials for paths that require them, or undefined for local paths.
// Vault access only occurs when the path prefix is "s3:".
//
async function fetchS3CredentialsForPath(rootPath: string): Promise<IS3Credentials | undefined> {
    if (rootPath.startsWith('s3:')) {
        return getDefaultS3Config();
    }

    return undefined;
}

//
// Creates storage for the given path, fetching S3 credentials from the vault only
// when the path prefix requires them. Local paths never touch the vault.
//
export async function createStorageForPath(rootPath: string, options?: IStorageOptions): Promise<ICreateStorageResult> {
    const s3Config = await fetchS3CredentialsForPath(rootPath);
    return createStorage(rootPath, s3Config, options);
}
