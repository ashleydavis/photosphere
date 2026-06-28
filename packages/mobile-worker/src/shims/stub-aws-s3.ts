//
// Build-time stub for `@aws-sdk/client-s3` in the mobile worker bundle.
//
// `createStorage` statically imports CloudStorage, which imports the AWS SDK. The mobile read path
// only ever opens local (fs:) databases, never s3:, so bundling the real SDK into the embedded
// engine would add a large, engine-incompatible dependency for code that never runs. This stub
// satisfies the imports; any actual S3 use throws the loud NOT IMPLEMENTED error. S3 support on
// mobile is a later layer (see plan-mobile-storage-options.md).
//

//
// Builds the NOT IMPLEMENTED error thrown if S3 is actually used on mobile.
//
function notImplemented(name: string): Error {
    return new Error(`NOT IMPLEMENTED: S3 ("${name}") is not available in the mobile worker. Implement it ASAP.`);
}

//
// Stub S3 client; constructing it is harmless, using it is not (CloudStorage only constructs it for
// s3: paths, which the mobile read path never opens).
//
export class S3Client {
    //
    // Throws if any command is sent: real S3 is unavailable on mobile.
    //
    send(): never {
        throw notImplemented("S3Client.send");
    }
}

//
// Marker command stubs. They are only ever instantiated to pass to S3Client.send (which throws).
//
export class ListObjectsV2Command {}

//
// See ListObjectsV2Command.
//
export class HeadObjectCommand {}

//
// See ListObjectsV2Command.
//
export class GetObjectCommand {}

//
// See ListObjectsV2Command.
//
export class PutObjectCommand {}

//
// See ListObjectsV2Command.
//
export class DeleteObjectCommand {}

//
// See ListObjectsV2Command.
//
export class DeleteObjectsCommand {}

//
// See ListObjectsV2Command.
//
export class CopyObjectCommand {}

//
// Type-only placeholder kept as a value export so a mixed value/type import resolves.
//
export class ListObjectsV2CommandOutput {}
