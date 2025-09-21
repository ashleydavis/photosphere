# CloudStorage Tests

This directory contains comprehensive tests for the CloudStorage implementation, including write lock functionality. These tests require real AWS S3 credentials and will create/delete objects in an S3 bucket.

## Setup

### 1. AWS Credentials

You need valid AWS credentials with read/write access to an S3 bucket. Set these environment variables:

```bash
export AWS_ACCESS_KEY_ID="your_access_key_here"
export AWS_SECRET_ACCESS_KEY="your_secret_key_here"
export TEST_S3_BUCKET="your-test-bucket-name"
export AWS_DEFAULT_REGION="us-east-1"
```

### 2. S3-Compatible Services (Optional)

If you're using a S3-compatible service like DigitalOcean Spaces, MinIO, etc., also set:

```bash
export AWS_ENDPOINT="https://your-s3-compatible-endpoint.com"
```

### 3. Test Bucket

The tests require a dedicated S3 bucket for testing. **Do not use a production bucket!** The tests will:
- Create and delete many test objects
- Test error conditions that might generate warnings in logs
- Clean up automatically, but failures could leave test objects behind

## Running the Tests

### Option 1: Using the Test Runner Script (Recommended)

```bash
./run-cloud-storage-tests.sh
```

The script will:
- Check that all required environment variables are set
- Show you what credentials are being used (partially hidden for security)
- Warn you about S3 operations
- Ask for confirmation before running tests
- Run the tests and report results

### Option 2: Direct Bun Command

```bash
cd packages/storage
bun test integration-tests/cloud-storage.test.ts
```

### Option 3: Manual Environment Setup

```bash
# Set your credentials
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export TEST_S3_BUCKET="my-test-bucket"
export AWS_DEFAULT_REGION="us-east-1"

# Run tests
cd packages/storage
bun test integration-tests/cloud-storage.test.ts
```

## Test Coverage

The test suite covers:

### Basic File Operations
- Writing and reading files
- File existence checks
- Getting file metadata
- Deleting files
- Error handling for non-existent files

### Directory Operations
- Directory existence checks
- Checking if directories are empty
- Listing files and subdirectories
- Deleting directories and contents

### Stream Operations
- Writing data via streams
- Reading data via streams
- Handling stream errors

### Write Lock Operations
- **Atomic lock acquisition** using S3 conditional writes
- **Race condition handling** with concurrent lock attempts
- **Lock information storage** (owner, timestamp)
- **Lock release** and cleanup
- **Lock lifecycle management**

### Error Handling
- Invalid bucket/key combinations
- Read-only storage mode enforcement
- Network and permission errors

### Path Handling
- Various path formats (simple, nested, with spaces, special characters)
- Leading slash normalization
- S3 key format compliance

## Write Lock Tests

The write lock tests are particularly important because they verify:

1. **Atomic Operations**: Uses S3's `If-None-Match: *` header to ensure lock files are created atomically
2. **Concurrency**: Multiple processes trying to acquire the same lock simultaneously 
3. **Race Conditions**: Validates that only one process can acquire a lock, even under high concurrency
4. **Data Integrity**: Lock files contain valid JSON with owner and timestamp information
5. **Lifecycle**: Complete workflow from lock acquisition to release

### Race Condition Test

The concurrent lock test is especially valuable:
- Creates 5 simultaneous lock acquisition attempts
- Verifies exactly one succeeds 
- Confirms the lock file exists and contains valid data
- Demonstrates S3's conditional write feature working correctly

## Safety Features

- **Unique Test Prefixes**: All test objects use timestamped prefixes to avoid conflicts
- **Automatic Cleanup**: Tests clean up after themselves in `afterEach`/`afterAll` hooks
- **Isolated Tests**: Each test uses unique file names to prevent interference
- **Read-Only Verification**: Tests confirm read-only mode prevents write operations

## Troubleshooting

### Common Issues

1. **Missing Environment Variables**
   ```
   Error: Missing required environment variable: AWS_ACCESS_KEY_ID
   ```
   Solution: Set all required environment variables listed above

2. **Invalid Credentials**
   ```
   InvalidAccessKeyId: The AWS Access Key Id you provided does not exist
   ```
   Solution: Verify your AWS credentials are correct and active

3. **Bucket Permissions**
   ```
   AccessDenied: Access Denied
   ```
   Solution: Ensure your AWS credentials have read/write access to the test bucket

4. **Bucket Doesn't Exist**
   ```
   NoSuchBucket: The specified bucket does not exist
   ```
   Solution: Create the bucket or use an existing bucket you have access to

5. **Network Issues**
   ```
   NetworkingError: getaddrinfo ENOTFOUND
   ```
   Solution: Check your internet connection and AWS endpoint configuration

### Debugging

To see more detailed output, run tests with verbose logging:

```bash
# Enable AWS SDK debug logging
export AWS_SDK_LOAD_CONFIG=1
export AWS_SDK_JS_LOG_LEVEL=debug

# Run tests
bun test integration-tests/cloud-storage.test.ts
```

## Cost Considerations

These tests will incur minimal AWS costs:
- S3 PUT requests: ~50-100 requests per test run
- S3 GET requests: ~50-100 requests per test run  
- S3 DELETE requests: ~50-100 requests per test run
- Storage: Minimal (test objects are small and quickly deleted)

Total cost per test run should be well under $0.01 USD for most AWS regions.

## CI/CD Integration

To run these tests in CI/CD pipelines:

```yaml
# Example GitHub Actions step
- name: Run CloudStorage Tests
  env:
    AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    TEST_S3_BUCKET: ${{ secrets.TEST_S3_BUCKET }}
    AWS_DEFAULT_REGION: us-east-1
  run: |
    cd packages/storage
    bun test src/tests/cloud-storage.test.ts
```

Store your AWS credentials as repository secrets for security.