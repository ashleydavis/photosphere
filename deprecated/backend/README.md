# Photosphere backend

This is the backend for the Photosphere application. It is a REST API to upload, managed and retrieve assets like photos and videos.

## Setup

First, follow the instructions in [the main readme](../../README.md).

Then open a terminal and change directory to the backend project:

```bash
cd apps/backend
```

## Run it in development

Start the application in development mode with live reload:

```bash
bun run start:dev
```

### Run with a single local directory

You can run the backend pointing to a single local directory (similar to the CLI's UI command) using the `--path` argument:

```bash
bun run start:single /path/to/your/photo/directory
# or
bun run start --path /path/to/your/photo/directory
```

This mode:
- Uses the specified directory as the asset storage location
- Creates a `.db` subdirectory for metadata storage
- Automatically sets `AUTH_TYPE=no-auth` and `APP_MODE=readwrite`
- Runs on port 3000 (configurable via `PORT` environment variable)

Example:
```bash
# Run backend on a local photo directory
bun run start:single ~/Pictures/MyPhotos

# With a custom port
PORT=8080 bun run start:single ~/Pictures/MyPhotos

# Or using the --path argument directly
PORT=3000 bun run start --path ~/Pictures/MyPhotos
```

## Test the REST API

Install [VS Code REST Client](https://marketplace.visualstudio.com/items?itemName=humao.rest-client) and you can use the HTTP request scripts in `./test/backend.http` to test the endpoints in the REST API.

## Run the backend locally in production mode

Compile the whole project:

```bash
bun run compile
```

Set the following environment variables:

```bash
export NODE_ENV=production
export APP_MODE=readwrite
export AUTH_TYPE=auth0
export AUTH0_AUDIENCE=...
export AUTH0_BASE_URL=...
export PORT=3000
export ASSET_STORAGE_CONNECTION=s3:your-s3-bucket-name:/sets
export DB_STORAGE_CONNECTION=s3:your-s3-bucket-name:/database
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=ap-southeast-2
export AWS_ENDPOINT=...endpoint for S3 on Digital Ocean...
```

Run the backend in production mode:

```bash
cd backend
bun start
```

## Run in production

Make sure relevant environment variables are set.

Start the application in production mode:

```bash
bun run start
```

## Run tests

```bash
bun run test
```

## Environment variables

- `NODE_ENV` - Set to "production" to enable AWS cloud storage.
- `APP_MODE` - Can be set to `readonly` or `readwrite`.
- `AUTH_TYPE` - The type of auth to use, can be set to `auth0` or `no-auth`.
- `ASSET_STORAGE_CONNECTION` - Defines the connection to storage that contains asset databases, examples:
    - `s3:your-s3-bucket:`
    - `s3:your-s3-bucket/a-sub-directory`
    - `fs:the/local/file-system`
- `DB_STORAGE_CONNECTION` - Defines the connection to storage that contains the Photosphere backend's general purpose database (user records are contained here).
- `PORT` - Port to run the web server on.

If using S3 for storage:

- `AWS_DEFAULT_REGION` - Sets the AWS region.
- `AWS_ACCESS_KEY_ID` - The access key for your AWS account.
- `AWS_SECRET_ACCESS_KEY` - The secret access key for your AWS account.
- `AWS_ENDPOINT` - Custom endpoint if required. This is used for contecting to Digital Ocean Spaces instead of AWS S3.


### Auth0 authentication details:

Set `AUTH_TYPE` TO `auth0`, then set the following from your Auth0 configuration:
- `AUTH0_DOMAIN`
- `AUTH0_AUDIENCE`
- `AUTH0_CLIENT_ID`
- `AUTH0_REDIRECT_URL`

## Run the Docker container for testing

```bash
cd photosphere
docker compose up --build
```

### Deploy the image to Dockerhub

```bash
cd photosphere
export VERSION=?
docker build -t codecapers/photosphere:$VERSION -t codecapers/photosphere:latest .
docker push codecapers/photosphere:$VERSION
docker push codecapers/photosphere:latest
```

Test the deployed image:

```bash
docker run codecapers/photosphere:$VERSION
```