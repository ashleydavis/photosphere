# Storage Paths

Every place that names a database or a storage location takes the same kind of path: the `--db` option on a CLI command, the **Path** and **Origin** fields in the app, a replication destination, and the `path` and `origin` recorded in `databases.toml`. This is what those paths may look like.

The prefix decides which storage is used. `fs:` is the local filesystem, `s3:` is an S3 compatible bucket, and a path with no prefix at all is treated as a local filesystem path. See `createStorage` in `packages/storage/src/lib/storage-factory.ts`.

## Local filesystem

```
fs:/home/me/photos          an absolute path
fs:./photos                 a relative path, resolved against the working directory
/home/me/photos             no prefix, so the local filesystem is assumed
./photos                    the same, relative
C:\Users\me\photos          Windows, backslashes are converted to forward slashes
```

The path after `fs:` is resolved to an absolute path, so a relative one depends on where the command was run from. Backslashes become forward slashes, which is why a Windows path and a Unix one behave the same everywhere below the storage layer.

## S3 and S3 compatible buckets

The bucket and the key within it are separated by a **slash**:

```
s3:my-bucket                the top of the bucket
s3:my-bucket/photos         the "photos" prefix inside the bucket
s3:my-bucket/a/b/c          a deeper prefix
```

`s3:my-bucket:/photos` is **not** a valid path, and nothing should produce one. The bucket is taken as everything up to the first slash (`parseS3ListPath` in `packages/storage/src/lib/s3-path.ts`), so the colon form asks for a bucket literally named `my-bucket:`, and the server answers that no such bucket exists. The error names the bucket that does exist, which makes it read like a problem with the bucket rather than with the path.

Several databases can share one bucket by using different prefixes. Each one sees only its own files.

## Credentials for an S3 path

A path on its own carries no credentials. They are resolved in this order:

1. The credentials registered against the database entry, when the database is named rather than given as a raw path. This is what `Configure secrets…` in the app sets, and what `s3_key` in `databases.toml` records.
2. The `default:s3` entry in the vault, when there is one. It holds the access key, the secret, the region and the endpoint.
3. The AWS SDK's own environment variables: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_REGION`.

The endpoint comes from the vault entry when there is one, and otherwise from `AWS_ENDPOINT`. A bucket that is not on real AWS (DigitalOcean Spaces, MinIO, a local S3 server) needs it set, or the request goes to AWS and reports that the bucket does not exist. Spaces are regional, so the endpoint names the region the bucket is in, for example `https://syd1.digitaloceanspaces.com`.

## Encrypted storage

Encryption is not part of the path. A database is encrypted by the keys it was created with, and the same `fs:` or `s3:` path names it either way. The storage layer reports the type as `encrypted-fs` or `encrypted-s3` once the keys are supplied, but nothing about the path says so.
