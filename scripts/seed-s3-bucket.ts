//
// Seeds the local S3 emulator's bucket through the S3 API, so the S3 browser has something to list.
//
// Run by scripts/s3-emulator.sh once the server reports healthy. Everything goes through the real
// AWS SDK against a plain-HTTP endpoint, which is the same path the app takes, so a seed that
// succeeds is itself evidence the endpoint is reachable and the credentials work.
//
// Usage: bun scripts/seed-s3-bucket.ts --endpoint <url> --bucket <name> --access-key <id> --secret-key <secret> --prefixes <a,b>
//

import { S3Client, CreateBucketCommand, PutObjectCommand, HeadBucketCommand } from "@aws-sdk/client-s3";

//
// The settings the seeder was invoked with.
//
interface ISeedOptions {
    // The S3 endpoint URL of the emulator, for example http://127.0.0.1:9000.
    endpoint: string;

    // The bucket to create and seed.
    bucket: string;

    // The access key id the emulator was started with.
    accessKeyId: string;

    // The secret access key the emulator was started with.
    secretAccessKey: string;

    // The directory prefixes to create inside the bucket.
    prefixes: string[];
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
// Parses the command line into the seeder's settings.
//
function parseOptions(argv: string[]): ISeedOptions {
    return {
        endpoint: requiredArg(argv, "endpoint"),
        bucket: requiredArg(argv, "bucket"),
        accessKeyId: requiredArg(argv, "access-key"),
        secretAccessKey: requiredArg(argv, "secret-key"),
        prefixes: requiredArg(argv, "prefixes").split(",").filter(prefix => prefix.length > 0),
    };
}

//
// Creates the bucket and writes one object under each seeded prefix, so each prefix shows up as a
// directory in a delimited listing. A prefix with no object under it does not exist as far as S3 is
// concerned, so the object is what makes the directory real.
//
async function seedBucket(options: ISeedOptions): Promise<void> {
    const s3Client = new S3Client({
        endpoint: options.endpoint,
        region: "us-east-1",
        forcePathStyle: true,
        credentials: {
            accessKeyId: options.accessKeyId,
            secretAccessKey: options.secretAccessKey,
        },
    });

    try {
        await s3Client.send(new HeadBucketCommand({ Bucket: options.bucket }));
        console.log(`Bucket ${options.bucket} already exists.`);
    }
    catch (err) {
        await s3Client.send(new CreateBucketCommand({ Bucket: options.bucket }));
        console.log(`Created bucket ${options.bucket}.`);
    }

    for (const prefix of options.prefixes) {
        const key = `${prefix}/seeded.txt`;
        await s3Client.send(new PutObjectCommand({
            Bucket: options.bucket,
            Key: key,
            Body: Buffer.from(`Seeded by scripts/seed-s3-bucket.ts for the S3 smoke tests.\n`, "utf8"),
            ContentType: "text/plain",
        }));
        console.log(`Seeded ${options.bucket}/${key}.`);
    }

    s3Client.destroy();
}

await seedBucket(parseOptions(process.argv.slice(2)));
