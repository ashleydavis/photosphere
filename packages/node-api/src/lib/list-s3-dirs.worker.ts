import type { ITaskContext } from "task-queue";
import { CloudStorage, type IS3Credentials } from "storage";
import { getVault, getDefaultVaultType } from "vault";

//
// Input for the list-s3-dirs task: the vault secret name holding the S3 credentials, the bucket, and
// the prefix under which to list directories. Mirrors the desktop `list-s3-dirs` IPC request, but runs
// as a background task on mobile because the WebView has no S3 client or vault access; the worker does.
//
export interface IListS3DirsData {
    // The vault secret name identifying the S3 credentials.
    s3Key: string;

    // The bucket to list.
    bucket: string;

    // The prefix (directory path) under the bucket to list.
    prefix: string;
}

//
// Output of the list-s3-dirs task: the directory names under the bucket/prefix.
//
export interface IListS3DirsResult {
    // The immediate subdirectory names under the requested prefix.
    names: string[];
}

//
// Parses an S3 credentials vault secret value (JSON) into the CloudStorage credentials shape. Exported
// and kept pure so it is unit-testable without a vault or network.
//
export function parseS3Credentials(secretValue: string): IS3Credentials {
    const parsed = JSON.parse(secretValue);
    return {
        accessKeyId: parsed.accessKeyId,
        secretAccessKey: parsed.secretAccessKey,
        region: parsed.region,
        endpoint: parsed.endpoint,
    };
}

//
// Background task handler that lists the directories under an S3 bucket/prefix, using the credentials
// stored in the device keychain under `s3Key`. Throws when the credentials are not configured, so the
// S3 browser surfaces a real error rather than rendering an empty bucket (the stub returned []).
//
export async function listS3DirsHandler(
    data: IListS3DirsData,
    _context: ITaskContext
): Promise<IListS3DirsResult> {
    const vault = getVault(getDefaultVaultType());
    const secret = await vault.get(data.s3Key);
    if (!secret) {
        throw new Error(`S3 credentials "${data.s3Key}" are not configured.`);
    }

    const credentials = parseS3Credentials(secret.value);
    const storage = new CloudStorage(data.bucket, credentials);
    const result = await storage.listDirs(`${data.bucket}/${data.prefix}`, 100);
    return { names: result.names };
}
