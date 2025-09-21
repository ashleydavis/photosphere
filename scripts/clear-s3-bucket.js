#!/usr/bin/env node

// Script to clear all objects from an S3 bucket
// Usage: node clear-s3-bucket.js <bucket-name>

import AWS from 'aws-sdk';

const bucketName = process.argv[2];

if (!bucketName) {
    console.error('❌ Error: Bucket name is required');
    console.error('Usage: node clear-s3-bucket.js <bucket-name>');
    process.exit(1);
}

// Check for required AWS credentials
if (!process.env.AWS_ACCESS_KEY_ID || !process.env.AWS_SECRET_ACCESS_KEY) {
    console.error('❌ Error: AWS credentials not found');
    console.error('Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables');
    process.exit(1);
}

// Configure AWS SDK
const s3Config = {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID,
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY,
    region: process.env.AWS_REGION || 'us-east-1'
};

if (process.env.AWS_ENDPOINT) {
    s3Config.endpoint = process.env.AWS_ENDPOINT;
}

const s3 = new AWS.S3(s3Config);

async function clearBucket() {
    try {
        console.log(`🧹 Clearing all objects from bucket: ${bucketName}`);
        
        let continuationToken = undefined;
        let totalDeleted = 0;
        
        do {
            // List objects in the bucket
            const listParams = {
                Bucket: bucketName,
                MaxKeys: 1000,
                ContinuationToken: continuationToken
            };
            
            const listResult = await s3.listObjectsV2(listParams).promise();
            
            if (!listResult.Contents || listResult.Contents.length === 0) {
                break;
            }
            
            // Prepare objects for deletion
            const objectsToDelete = listResult.Contents.map(obj => ({
                Key: obj.Key
            }));
            
            // Delete objects in batch
            const deleteParams = {
                Bucket: bucketName,
                Delete: {
                    Objects: objectsToDelete,
                    Quiet: true
                }
            };
            
            const deleteResult = await s3.deleteObjects(deleteParams).promise();
            totalDeleted += objectsToDelete.length;
            
            console.log(`   Deleted ${objectsToDelete.length} objects (${totalDeleted} total)`);
            
            continuationToken = listResult.NextContinuationToken;
            
        } while (continuationToken);
        
        if (totalDeleted === 0) {
            console.log(`✅ Bucket ${bucketName} was already empty`);
        } else {
            console.log(`✅ Successfully deleted ${totalDeleted} objects from bucket ${bucketName}`);
        }
        
    } catch (error) {
        console.error(`❌ Error clearing bucket: ${error.message}`);
        
        if (error.code === 'NoSuchBucket') {
            console.error(`   Bucket "${bucketName}" does not exist`);
        } else if (error.code === 'AccessDenied') {
            console.error(`   Access denied to bucket "${bucketName}"`);
            console.error(`   Please check your AWS credentials and bucket permissions`);
        }
        
        process.exit(1);
    }
}

clearBucket();