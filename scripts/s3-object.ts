//
// Inspects and manipulates objects in a bucket for the S3 smoke tests, so a shell test can count,
// list, write, read, delete and bulk-seed objects without an S3 client on the path.
//
// Shell cannot sign an S3 request, and neither `aws` nor `jq` is a declared dependency of this
// repository, so this is the TypeScript helper CLAUDE.md describes for the case where shell genuinely
// cannot do the job. Everything goes through the real AWS SDK with path-style addressing, exactly as
// scripts/seed-s3-bucket.ts does, against a plain-HTTP endpoint.
//
// Usage:
//   bun scripts/s3-object.ts <subcommand> --endpoint <url> --bucket <name> --access-key <id> --secret-key <secret> [options]
//
// Subcommands:
//   count      --prefix <p>                Prints the number of objects under the prefix.
//   list       --prefix <p>                Prints one object key per line, in listing order.
//   put        --key <k> --body <string>   Writes an object with the given string as its body.
//   get        --key <k>                   Prints an object's bytes to stdout.
//   delete     --key <k>                   Deletes one object.
//   seed-many  --prefix <p> --count <n>    Writes n small objects under the prefix, for the paging test.
//
// `count` and `list` follow continuation tokens to the end of the listing, so they see past the
// 1000-key first page that a single ListObjectsV2 returns.
//

import { S3Client, ListObjectsV2Command, PutObjectCommand, GetObjectCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";

//
// How many seed-many uploads are in flight at once. Enough to keep the local server busy without
// opening a thousand sockets at once, which exhausts the SDK's connection pool and stalls.
//
const SEED_CONCURRENCY = 32;

//
// The connection settings every subcommand needs.
//
interface IConnectionOptions {
    // The S3 endpoint URL of the emulator, for example http://127.0.0.1:9000.
    endpoint: string;

    // The bucket to operate on.
    bucket: string;

    // The access key id the emulator was started with.
    accessKeyId: string;

    // The secret access key the emulator was started with.
    secretAccessKey: string;
}

//
// Reads a required `--name value` argument from the command line, failing loudly when it is absent.
//
function requiredArg(argv: string[], name: string): string {
    const index = argv.indexOf(`--${name}`);
    if (index === -1 || index + 1 >= argv.length) {
        throw new Error(`Missing required argument --${name}`);
    }
    return argv[index + 1];
}

//
// Parses the connection settings shared by every subcommand.
//
function parseConnectionOptions(argv: string[]): IConnectionOptions {
    return {
        endpoint: requiredArg(argv, "endpoint"),
        bucket: requiredArg(argv, "bucket"),
        accessKeyId: requiredArg(argv, "access-key"),
        secretAccessKey: requiredArg(argv, "secret-key"),
    };
}

//
// Builds the S3 client. `forcePathStyle` is what keeps the bucket in the path rather than the
// hostname: a virtual-hosted request to a local server names no bucket, which returns an empty
// listing rather than an error, and an empty listing is the silent wrong answer these tests exist to
// catch.
//
function createClient(options: IConnectionOptions): S3Client {
    return new S3Client({
        endpoint: options.endpoint,
        region: "us-east-1",
        forcePathStyle: true,
        credentials: {
            accessKeyId: options.accessKeyId,
            secretAccessKey: options.secretAccessKey,
        },
    });
}

//
// Lists every object key under a prefix, following continuation tokens to the end of the listing.
//
async function listKeys(s3Client: S3Client, bucket: string, prefix: string): Promise<string[]> {
    const keys: string[] = [];
    let continuationToken: string | undefined = undefined;

    do {
        const response = await s3Client.send(new ListObjectsV2Command({
            Bucket: bucket,
            Prefix: prefix,
            ContinuationToken: continuationToken,
        }));

        for (const object of response.Contents || []) {
            if (object.Key) {
                keys.push(object.Key);
            }
        }

        continuationToken = response.IsTruncated ? response.NextContinuationToken : undefined;
    }
    while (continuationToken);

    return keys;
}

//
// Writes one object with a string body.
//
async function putObject(s3Client: S3Client, bucket: string, key: string, body: string): Promise<void> {
    await s3Client.send(new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        Body: Buffer.from(body, "utf8"),
    }));
}

//
// Reads one object and writes its bytes to stdout, so a test can compare them against something.
//
async function getObject(s3Client: S3Client, bucket: string, key: string): Promise<void> {
    const response = await s3Client.send(new GetObjectCommand({
        Bucket: bucket,
        Key: key,
    }));
    if (!response.Body) {
        throw new Error(`Object ${bucket}/${key} came back with no body`);
    }
    const bytes = await response.Body.transformToByteArray();
    process.stdout.write(Buffer.from(bytes));
}

//
// Deletes one object.
//
async function deleteObject(s3Client: S3Client, bucket: string, key: string): Promise<void> {
    await s3Client.send(new DeleteObjectCommand({
        Bucket: bucket,
        Key: key,
    }));
}

//
// Writes many small objects under a prefix, a bounded number at a time, so a listing over that prefix
// has to page to see them all.
//
async function seedMany(s3Client: S3Client, bucket: string, prefix: string, count: number): Promise<void> {
    let nextIndex = 0;

    //
    // One worker pulls indexes off the shared counter until they run out, which keeps exactly
    // SEED_CONCURRENCY uploads in flight rather than starting all of them at once.
    //
    async function uploadWorker(): Promise<void> {
        while (true) {
            const index = nextIndex;
            nextIndex += 1;
            if (index >= count) {
                return;
            }
            const paddedIndex = String(index).padStart(6, "0");
            await putObject(s3Client, bucket, `${prefix}/object-${paddedIndex}.txt`, `seeded object ${paddedIndex}\n`);
        }
    }

    const workers: Promise<void>[] = [];
    for (let workerIndex = 0; workerIndex < Math.min(SEED_CONCURRENCY, count); workerIndex += 1) {
        workers.push(uploadWorker());
    }
    await Promise.all(workers);
}

//
// Dispatches the requested subcommand.
//
async function main(argv: string[]): Promise<void> {
    const subcommand = argv[0];
    if (!subcommand || subcommand.startsWith("--")) {
        throw new Error("Expected a subcommand: count, list, put, get, delete or seed-many");
    }

    const options = parseConnectionOptions(argv);
    const s3Client = createClient(options);

    try {
        switch (subcommand) {
            case "count": {
                const keys = await listKeys(s3Client, options.bucket, requiredArg(argv, "prefix"));
                console.log(keys.length);
                break;
            }

            case "list": {
                const keys = await listKeys(s3Client, options.bucket, requiredArg(argv, "prefix"));
                for (const key of keys) {
                    console.log(key);
                }
                break;
            }

            case "put": {
                await putObject(s3Client, options.bucket, requiredArg(argv, "key"), requiredArg(argv, "body"));
                break;
            }

            case "get": {
                await getObject(s3Client, options.bucket, requiredArg(argv, "key"));
                break;
            }

            case "delete": {
                await deleteObject(s3Client, options.bucket, requiredArg(argv, "key"));
                break;
            }

            case "seed-many": {
                const count = Number(requiredArg(argv, "count"));
                if (!Number.isInteger(count) || count < 1) {
                    throw new Error(`--count must be a positive whole number, got "${requiredArg(argv, "count")}"`);
                }
                await seedMany(s3Client, options.bucket, requiredArg(argv, "prefix"), count);
                break;
            }

            default:
                throw new Error(`Unknown subcommand "${subcommand}". Expected count, list, put, get, delete or seed-many.`);
        }
    }
    finally {
        s3Client.destroy();
    }
}

await main(process.argv.slice(2));
