
//
// Database connection configuration encoded in a QR code.
//
export interface IDatabaseQrConfig {
    //
    // Display name for the database.
    //
    name: string;

    //
    // Storage path for the database, e.g. "s3:bucket/path".
    //
    path: string;

    //
    // Storage connection details.
    //
    storage: {
        //
        // S3-compatible endpoint URL.
        //
        endpoint: string;

        //
        // Storage region.
        //
        region: string;

        //
        // Access key ID for storage authentication.
        //
        accessKeyId: string;

        //
        // Secret access key for storage authentication.
        //
        secretAccessKey: string;
    };

    //
    // PEM-encoded private key used to encrypt the database.
    //
    encryptionKey: string;
}

//
// Format code for the current serialization version.
//
const FORMAT_CODE = "1";

//
// ASCII Unit Separator — a control character that will never appear in
// database names, paths, URLs, or storage keys.
//
const UNIT_SEPARATOR = "\x1F";

//
// Serializes a database config to a compact QR code payload.
// Format: <code><field\x1F...>
// Fields in order: name, path, endpoint, region, accessKeyId, secretAccessKey, encryptionKey.
//
export function serializeDatabaseQrConfig(config: IDatabaseQrConfig): string {
    return FORMAT_CODE + [
        config.name,
        config.path,
        config.storage.endpoint,
        config.storage.region,
        config.storage.accessKeyId,
        config.storage.secretAccessKey,
        config.encryptionKey,
    ].join(UNIT_SEPARATOR);
}

//
// Deserializes a QR code payload back into a database config.
// Throws if the format code is unrecognised.
//
export function deserializeDatabaseQrConfig(data: string): IDatabaseQrConfig {
    const formatCode = data[0];
    if (formatCode !== FORMAT_CODE) {
        throw new Error(`Unknown QR format code: ${formatCode}`);
    }
    const values = data.slice(1).split(UNIT_SEPARATOR);
    return {
        name: values[0],
        path: values[1],
        storage: {
            endpoint: values[2],
            region: values[3],
            accessKeyId: values[4],
            secretAccessKey: values[5],
        },
        encryptionKey: values[6],
    };
}
