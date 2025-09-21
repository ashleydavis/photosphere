#!/bin/bash

# CloudStorage Test Runner
# This script helps you run the CloudStorage tests with proper AWS credentials

echo "CloudStorage Test Runner"
echo "======================="
echo ""
echo "This script will run tests against real S3 storage."
echo "Make sure you have set the following environment variables:"
echo ""
echo "Required:"
echo "  AWS_ACCESS_KEY_ID      - Your AWS access key"
echo "  AWS_SECRET_ACCESS_KEY  - Your AWS secret key"
echo "  TEST_S3_BUCKET         - S3 bucket name for testing"
echo ""
echo "Optional:"
echo "  AWS_REGION             - AWS region (default: us-east-1)"
echo "  AWS_ENDPOINT           - Custom S3 endpoint (for S3-compatible services)"
echo ""

# Check if required environment variables are set
if [[ -z "$AWS_ACCESS_KEY_ID" ]]; then
    echo "❌ Missing AWS_ACCESS_KEY_ID"
    exit 1
fi

if [[ -z "$AWS_SECRET_ACCESS_KEY" ]]; then
    echo "❌ Missing AWS_SECRET_ACCESS_KEY"
    exit 1
fi

if [[ -z "$TEST_S3_BUCKET" ]]; then
    echo "❌ Missing TEST_S3_BUCKET"
    echo "   Please set this to an S3 bucket you have read/write access to."
    echo "   Example: export TEST_S3_BUCKET=my-test-bucket"
    exit 1
fi

# Set default region if not specified
if [[ -z "$AWS_REGION" ]]; then
    export AWS_REGION="us-east-1"
fi

echo "✅ Environment variables configured:"
echo "   AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:8}..."
echo "   AWS_SECRET_ACCESS_KEY: [hidden]"
echo "   TEST_S3_BUCKET: $TEST_S3_BUCKET"
echo "   AWS_REGION: $AWS_REGION"
if [[ -n "$AWS_ENDPOINT" ]]; then
    echo "   AWS_ENDPOINT: $AWS_ENDPOINT"
fi
echo ""

echo "⚠️  WARNING: These tests will CLEAR ALL CONTENTS from your S3 bucket!"
echo "   🪣 BUCKET: $TEST_S3_BUCKET"
echo "   This will permanently delete ALL objects in the bucket."
echo "   After clearing, tests will run and leave test artifacts in the bucket."
echo ""

read -p "Hit 'y' to confirm bucket clearing: " -n 1 -r first_y
echo
if [[ ! $first_y =~ ^[Yy]$ ]]; then
    echo "❌ Confirmation cancelled. Test run cancelled."
    exit 1
fi

read -p "Hit 'y' again to confirm: " -n 1 -r second_y
echo
if [[ ! $second_y =~ ^[Yy]$ ]]; then
    echo "❌ Second confirmation failed. Test run cancelled."
    exit 1
fi

echo ""
echo "🧹 Clearing S3 bucket before running tests..."
echo ""

# Clear the S3 bucket
node scripts/clear-s3-bucket.js "$TEST_S3_BUCKET"
CLEAR_EXIT_CODE=$?

if [[ $CLEAR_EXIT_CODE -ne 0 ]]; then
    echo ""
    echo "❌ Failed to clear S3 bucket. Cannot proceed with tests."
    exit $CLEAR_EXIT_CODE
fi

echo ""
echo "🧪 Running CloudStorage tests..."
echo ""

# Run the tests
cd packages/storage
bun test integration-tests/cloud-storage.test.ts

TEST_EXIT_CODE=$?

echo ""
if [[ $TEST_EXIT_CODE -eq 0 ]]; then
    echo "✅ All CloudStorage tests passed!"
    echo ""
    echo "📁 Test artifacts have been left in your S3 bucket for inspection:"
    echo "   Bucket: $TEST_S3_BUCKET"
    echo "   Prefix: test-[timestamp]-[random]/"
    echo ""
    echo "🔍 You can examine the test objects to verify S3 operations worked correctly."
else
    echo "❌ Some CloudStorage tests failed (exit code: $TEST_EXIT_CODE)"
    echo ""
    echo "📁 Partial test artifacts may remain in your S3 bucket:"
    echo "   Bucket: $TEST_S3_BUCKET"
fi

exit $TEST_EXIT_CODE