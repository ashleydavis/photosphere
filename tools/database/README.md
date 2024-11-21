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
export DB_CONNECTION_STRING=<db-connection-string>
```

Use `set` instead of `export` for Windows.

Run the database update script:

```bash
pnpm start
```

Run it for development with live reload:

```bash
pnpm run start:dev
```

## Arguments

Use `--asset` to just update one asset:

```bash
npm start -- --asset=<the-asset-id>
```

Use `--set` to just update one set:

```bash
npm start -- --set=<the-set-id>
```

