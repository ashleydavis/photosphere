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
export DB_BACKUP_TARGET_DIR=<target-directory-for-the-backup>
```

Use `set` instead of `export` for Windows.

Run the backup:

```bash
npm start
```

Run it for development with live reload:

```bash
pnpm run start:dev
```


