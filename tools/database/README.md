# Database

A tool for updating the Photosphere database.

Run this to when you need to make mass changes to the Photosphere database.

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

Change into directory for the tool and run it:

```bash
cd tools/database
```

Set set environnment variables for the database connection and AWS:

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

## Arguments

Use `--asset` to just modify one asset:

```bash
npm start -- --asset=<the-asset-id>
```

Use `--set` to just modify one set:

```bash
npm start -- --set=<the-set-id>
```

