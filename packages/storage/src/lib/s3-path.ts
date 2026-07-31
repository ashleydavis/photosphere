//
// The bucket and key that an S3 storage path resolves to.
//
export interface IS3PathParts {
    //
    // The bucket name, always non-empty.
    //
    bucket: string;

    //
    // The key within the bucket. Empty when the path names the top of the bucket.
    //
    key: string;
}

//
// Splits an S3 listing path into its bucket and key.
//
// Unlike the path parsing used for naming a single file, an empty key is allowed here, because
// listing the top of a bucket is a legitimate request: it is what the S3 browser asks for the
// moment it is opened. Both `my-bucket` and `my-bucket/` name the top of `my-bucket`.
//
export function parseS3ListPath(path: string): IS3PathParts {
    const slashIndex = path.indexOf("/");
    const bucket = slashIndex === -1 ? path : path.slice(0, slashIndex);
    const key = slashIndex === -1 ? "" : path.slice(slashIndex + 1);

    if (bucket.length === 0) {
        throw new Error(`Invalid path: ${path}. Expected <bucket-name> or <bucket-name>/<path>`);
    }

    return {
        bucket,
        key,
    };
}
