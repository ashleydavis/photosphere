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

## Run in production

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
- `AUTH_TYPE` - The type of auth to use, can be set to `auth0` or `no-auth`.
- `AWS_BUCKET` - Sets the name of the AWS S3 bucket to use for storage.
- `AWS_DEFAULT_REGION` - Sets the AWS region.
- `AWS_ACCESS_KEY_ID` - The access key for your AWS account.
- `AWS_SECRET_ACCESS_KEY` - The secret access key for your AWS account.
- `AWS_ENDPOINT` - Custom endpoint if required. This is used for contecting to Digital Ocean Spaces instead of AWS S3.
- `DB_CONNECTION_STRING` - Connection string for the MongoDB database server.
- `DB_NAME` - The name of the datbaase for the app to use.
- `PORT` - Port to run the web server on.


### Auth0 authentication details:

Set `AUTH_TYPE` TO `auth0`, then set the following from your Auth0 configuration:
- `AUTH0_DOMAIN`
- `AUTH0_BASE_URL`
