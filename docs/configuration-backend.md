# Photosphere Backend Configuration Guide

This guide covers all configuration options available for the Photosphere backend service, including environment variables, storage options, and authentication settings.

## Environment Variables

### Required Environment Variables

| Variable | Description | Valid Values | Example |
|----------|-------------|--------------|---------|
| `PORT` | Port number for the web server | Any valid port number | `3000` |
| `ASSET_STORAGE_CONNECTION` | Connection string for asset storage | See [Storage Connections](#storage-connections) | `s3:my-bucket/assets` |
| `DB_STORAGE_CONNECTION` | Connection string for database storage | See [Storage Connections](#storage-connections) | `s3:my-bucket/database` |
| `APP_MODE` | Application mode | `readonly`, `readwrite` | `readwrite` |
| `AUTH_TYPE` | Authentication type | `auth0`, `no-auth` | `auth0` |

### Optional Environment Variables

#### General Configuration

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `NODE_ENV` | Node environment | `development` | `production` |
| `FRONTEND_STATIC_PATH` | Path to serve frontend static files | None | `./public` |
| `GOOGLE_API_KEY` | Google API key for reverse geocoding | None | `AIzaSy...` |

#### Storage Encryption

| Variable | Description | Example |
|----------|-------------|---------|
| `ASSET_STORAGE_PRIVATE_KEY` | Private key content for encryption | PEM-formatted key string |
| `ASSET_STORAGE_PRIVATE_KEY_FILE` | Path to private key file | `./keys/private.pem` |

#### AWS S3 Configuration

Required when using S3 storage:

| Variable | Description | Example |
|----------|-------------|---------|
| `AWS_ACCESS_KEY_ID` | AWS access key ID | `AKIAIOSFODNN7EXAMPLE` |
| `AWS_SECRET_ACCESS_KEY` | AWS secret access key | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` |
| `AWS_DEFAULT_REGION` | AWS region | `us-east-1` |
| `AWS_ENDPOINT` | Custom S3 endpoint (for S3-compatible services) | `https://nyc3.digitaloceanspaces.com` |

#### Auth0 Configuration

Required when `AUTH_TYPE=auth0`:

| Variable | Description | Example |
|----------|-------------|---------|
| `AUTH0_DOMAIN` | Auth0 domain | `myapp.auth0.com` |
| `AUTH0_AUDIENCE` | Auth0 API audience | `https://api.myapp.com` |
| `AUTH0_CLIENT_ID` | Auth0 client ID | `a1b2c3d4e5f6...` |
| `AUTH0_REDIRECT_URL` | Auth0 redirect URL after login | `https://myapp.com/callback` |

## Storage Connections

Storage connection strings define where assets and database files are stored.

### Connection String Format

| Type | Format | Example |
|------|---------|---------|
| Filesystem | `fs:path/to/directory` | `fs:./files/collections` |
| S3-compatible | `s3:bucket-name` | `s3:my-photos-bucket` |
| S3 with prefix | `s3:bucket-name/prefix` | `s3:my-bucket/photosphere/assets` |

### Storage Types

1. **Asset Storage** (`ASSET_STORAGE_CONNECTION`)
   - Stores photo and video files
   - Organized by collections
   - Contains original, display, and thumbnail versions

2. **Database Storage** (`DB_STORAGE_CONNECTION`)
   - Stores user records
   - Contains application metadata
   - BSON format database files

## Configuration Examples

### Development Configuration

```bash
# Basic development setup with local storage
export PORT=3000
export NODE_ENV=development
export APP_MODE=readwrite
export AUTH_TYPE=no-auth
export ASSET_STORAGE_CONNECTION=fs:./files/collections
export DB_STORAGE_CONNECTION=fs:./files/database

# Optional: Add Google reverse geocoding
export GOOGLE_API_KEY=your-google-api-key
```

### Production Configuration with S3

```bash
# Production setup with AWS S3
export PORT=3000
export NODE_ENV=production
export APP_MODE=readwrite
export AUTH_TYPE=auth0

# Storage configuration
export ASSET_STORAGE_CONNECTION=s3:photosphere-assets/collections
export DB_STORAGE_CONNECTION=s3:photosphere-assets/database

# AWS credentials
export AWS_ACCESS_KEY_ID=your-access-key
export AWS_SECRET_ACCESS_KEY=your-secret-key
export AWS_DEFAULT_REGION=us-east-1

# Auth0 configuration
export AUTH0_DOMAIN=myapp.auth0.com
export AUTH0_AUDIENCE=https://api.photosphere.com
export AUTH0_CLIENT_ID=your-client-id
export AUTH0_REDIRECT_URL=https://photosphere.com/callback

# Optional features
export GOOGLE_API_KEY=your-google-api-key
```

### Production with DigitalOcean Spaces

```bash
# Production setup with DigitalOcean Spaces (S3-compatible)
export PORT=3000
export NODE_ENV=production
export APP_MODE=readwrite
export AUTH_TYPE=auth0

# Storage configuration
export ASSET_STORAGE_CONNECTION=s3:my-space/photosphere/assets
export DB_STORAGE_CONNECTION=s3:my-space/photosphere/database

# DigitalOcean Spaces credentials
export AWS_ACCESS_KEY_ID=your-do-access-key
export AWS_SECRET_ACCESS_KEY=your-do-secret-key
export AWS_DEFAULT_REGION=nyc3
export AWS_ENDPOINT=https://nyc3.digitaloceanspaces.com

# Auth0 configuration
export AUTH0_DOMAIN=myapp.auth0.com
export AUTH0_AUDIENCE=https://api.photosphere.com
export AUTH0_CLIENT_ID=your-client-id
export AUTH0_REDIRECT_URL=https://photosphere.com/callback
```

### Read-Only Mode with Encryption

```bash
# Read-only setup with encrypted storage
export PORT=3000
export NODE_ENV=production
export APP_MODE=readonly
export AUTH_TYPE=auth0

# Storage configuration
export ASSET_STORAGE_CONNECTION=s3:secure-bucket/assets
export DB_STORAGE_CONNECTION=s3:secure-bucket/database

# Encryption
export ASSET_STORAGE_PRIVATE_KEY_FILE=/secure/keys/photosphere.pem

# AWS credentials
export AWS_ACCESS_KEY_ID=your-access-key
export AWS_SECRET_ACCESS_KEY=your-secret-key
export AWS_DEFAULT_REGION=us-west-2
```

## Docker Configuration

When running in Docker, environment variables can be passed via:

1. **Docker run command**:
   ```bash
   docker run -p 3000:3000 \
     -e PORT=3000 \
     -e AUTH_TYPE=no-auth \
     -e APP_MODE=readwrite \
     -e ASSET_STORAGE_CONNECTION=fs:/data/assets \
     -e DB_STORAGE_CONNECTION=fs:/data/database \
     codecapers/photosphere:latest
   ```

2. **Docker Compose** (docker-compose.yaml):
   ```yaml
   services:
     photosphere:
       image: codecapers/photosphere:latest
       ports:
         - "3000:3000"
       environment:
         - PORT=3000
         - AUTH_TYPE=no-auth
         - APP_MODE=readwrite
         - ASSET_STORAGE_CONNECTION=fs:/data/assets
         - DB_STORAGE_CONNECTION=fs:/data/database
       volumes:
         - ./data:/data
   ```

3. **Environment file** (.env):
   ```bash
   docker run --env-file .env codecapers/photosphere:latest
   ```

## CORS Configuration

The backend automatically enables CORS for all origins. This is configured in the server setup and cannot be customized via environment variables.

## Server Features

### Static File Serving

When `FRONTEND_STATIC_PATH` is set, the backend will serve static files from that directory. This is useful for serving the frontend application from the same server.

### Health Check Endpoint

The server provides a health check endpoint at `/alive` that returns HTTP 200 when the server is running.

### Authentication Configuration Endpoint

The `/auth/config` endpoint returns the current authentication configuration, allowing the frontend to dynamically configure itself based on the backend settings.

## Security Considerations

1. **Credentials**: Never commit credentials to version control. Use environment variables or secure secret management systems.

2. **Encryption**: Use `ASSET_STORAGE_PRIVATE_KEY_FILE` to enable encryption for sensitive photo collections.

3. **Read-Only Mode**: Set `APP_MODE=readonly` for public-facing deployments where users should not be able to modify content.

4. **Auth0**: Always use `AUTH_TYPE=auth0` in production for proper user authentication and authorization.

5. **HTTPS**: Always use HTTPS in production, especially when using Auth0 authentication.

## Troubleshooting

### Common Issues

1. **Port Already in Use**
   ```bash
   Error: listen EADDRINUSE: address already in use :::3000
   ```
   Solution: Change the PORT environment variable or stop the conflicting process.

2. **Missing Required Environment Variables**
   ```
   Error: Set environment variable PORT.
   ```
   Solution: Ensure all required environment variables are set before starting the server.

3. **S3 Connection Errors**
   ```
   Error: Access Denied
   ```
   Solution: Verify AWS credentials and bucket permissions.

4. **Auth0 Configuration Issues**
   ```
   Error: Expected AUTH0_AUDIENCE environment variable
   ```
   Solution: Ensure all Auth0 environment variables are set when using `AUTH_TYPE=auth0`.

### Debug Mode

Enable verbose logging by setting:
```bash
export NODE_ENV=development
```

This will provide more detailed error messages and logging output.