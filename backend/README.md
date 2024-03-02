# Photosphere Node.js backend

This is the backend for [the Photosphere application](https://rapidfullstackdevelopment.com/example-application). It is a REST API to upload and retrieve assets like photos and videos.

## Setup

Open a terminal and change directory to the backend project:

```bash
cd photosphere-monorepo/backend
```

Install dependencies:

```bash
npm install
```

## Run it in development

Start the application in development mode with an instant dev database ([insta-mongo](https://www.npmjs.com/package/insta-mongo)) and live reload:

```bash
npm run start:dev
```

## Test the REST API

Install [VS Code REST Client](https://marketplace.visualstudio.com/items?itemName=humao.rest-client) and you can use the HTTP request scripts in `./test/backend.http` to test the endpoints in the REST API.

## Run in production

To run in production you will need a MongoDB database running.

The app will default by connecting to a local database on `mongodb://localhost:27017`.

You can connect to a different database (e.g. a MongoDB instance in the cloud) by setting this environment variable:

```bash
export DB_CONNECTION_STRING=<your db connection string>
```

Or on Windows:

```bash
set DB_CONNECTION_STRING=<your db connection string>
```

Start the application in production mode:

```bash
npm start
```

## Environment variables

- `NODE_ENV`    - Set to "production" to enable AWS cloud storage.
- `AWS_BUCKET`  - Sets the name of the AWS S3 bucket to use for storage.
- `AWS_DEFAULT_REGION`  - Sets the AWS region.
- `AWS_ACCESS_KEY_ID` - The access key for your AWS account.
- `AWS_SECRET_ACCESS_KEY` - The secret access key for your AWS account.
- `AWS_ENDPOINT` - Custom endpoint if required. This is used for contecting to Digital Ocean Spaces instead of AWS S3.
