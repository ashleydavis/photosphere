# Photosphere Node.js backend

This is the backend for the Photosphere application. It is a REST API to upload, managed and retrieve assets like photos and videos.

## Setup

First, follow the instructions in [the main readme](../README.md).

Then open a terminal and change directory to the backend project:

```bash
cd backend
```

## Run it in development

Start the application in development mode with live reload:

```bash
pnpm run start:dev
```

## Test the REST API

Install [VS Code REST Client](https://marketplace.visualstudio.com/items?itemName=humao.rest-client) and you can use the HTTP request scripts in `./test/backend.http` to test the endpoints in the REST API.

## Run the backend locally in production mode

Compile the whole project:

```bash
pnpm run compile
```

Compile in watch mode in another terminal, if you want to make changes to the code while it is running:

```bash
pnpm run compile:watch
```

Set the following environment variables:

```bash
export NODE_ENV=production
export APP_MODE=readwrite
export AUTH_TYPE=auth0
export AUTH0_AUDIENCE=...
export AUTH0_BASE_URL=...
export PORT=3000
export DB_CONNECTION_STRING=...
export DB_NAME=photosphere
export STORAGE_CONNECTION=s3:your-s3-bucket-name:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=ap-southeast-2
export AWS_ENDPOINT=... (if needed)
```

Run the backend in production mode:

```bash
cd backend
pnpm start
```

## Run in production

Make sure relevant environment variables are set.

Start the application in production mode:

```bash
pnpm start
```

## Run tests

```bash
pnpm test
```

## Environment variables

- `NODE_ENV` - Set to "production" to enable AWS cloud storage.
- `APP_MODE` - Can be set to `readonly` or `readwrite`.
- `AUTH_TYPE` - The type of auth to use, can be set to `auth0` or `no-auth`.
- `DB_CONNECTION_STRING` - Connection string for the MongoDB database server.
- `DB_NAME` - The name of the datbaase for the app to use.
- `STORAGE_CONNECTION` - Defines the connection to storage for the application, examples:
    - `s3:your-s3-bucket:`
    - `s3:your-s3-bucket/a-sub-directory`
    - `fs:the/local/file-system`
- `PORT` - Port to run the web server on.

If using S3 for storage:

- `AWS_DEFAULT_REGION` - Sets the AWS region.
- `AWS_ACCESS_KEY_ID` - The access key for your AWS account.
- `AWS_SECRET_ACCESS_KEY` - The secret access key for your AWS account.
- `AWS_ENDPOINT` - Custom endpoint if required. This is used for contecting to Digital Ocean Spaces instead of AWS S3.


### Auth0 authentication details:

Set `AUTH_TYPE` TO `auth0`, then set the following from your Auth0 configuration:
- `AUTH0_BASE_URL`
- `AUTH0_AUDIENCE`
