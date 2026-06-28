//
// Build-time stub for `@aws-sdk/lib-storage` in the mobile worker bundle.
//
// CloudStorage imports `Upload` for multipart S3 uploads. The mobile read path never uploads to S3,
// so this stub satisfies the import; constructing or using it throws the loud NOT IMPLEMENTED error.
//

//
// Stub multipart upload helper. Any use throws because S3 is unavailable on mobile.
//
export class Upload {
    //
    // Throws on construction: S3 uploads are not available in the mobile worker.
    //
    constructor() {
        throw new Error(`NOT IMPLEMENTED: S3 ("Upload") is not available in the mobile worker. Implement it ASAP.`);
    }
}
