
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
    // Passphrase used to deterministically derive the private key that encrypts the database.
    //
    passPhrase: string;
}
