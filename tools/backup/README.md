# Backup

A backup tool for Photosphere.

Run this to backup the Photosphere database and assets.

## Setup

Install dependencies for the monorepo:

```bash
cd photosphere
pnpm install
```

## Run it

Compile code:

```bash
pnpm run compile
```

Change into directory for the Backup tool and run it:

```bash
cd tools/backup
```

Set set environnment variables for the databsae connection and AWS:

```bash
export AWS_ACCESS_KEY_ID=<aws-key>
export AWS_SECRET_ACCESS_KEY=<aws-secret>
export AWS_BUCKET=<aws-bucket>
export AWS_DEFAULT_REGION=<aws-region>
export DB_CONNECTION_STRING=<db-connection-string>
export LOCAL_STORAGE_DIR=<local-directory-to-contain-assets>
```

Use `set` instead of `export` for Windows.

Run the backup from cloud to local:

```bash
pnpm start
```

Run it for development with live reload:

```bash
pnpm run start:dev
```

## Run it with source and dest specified

From cloud to local:

```bash
pnpm start -- --source=s3 --dest=local
```

From local to cloud:

```bash
pnpm start -- --source=local --dest=s3
```

## Arguments

Use `--source` and `--dest` to set the source and destination to `s3` or `local`.

Use `--asset` to just backup one asset:

```bash
npm start -- --asset=<the-asset-id>
```

Use `--set` to just backup one set:

```bash
npm start -- --set=<the-set-id>
```

