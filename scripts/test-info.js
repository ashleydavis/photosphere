#!/usr/bin/env node

import AWS from 'aws-sdk';

const s3 = new AWS.S3({
    endpoint: process.env.AWS_ENDPOINT,
    accessKeyId: process.env.AWS_ACCESS_KEY_ID,
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY,
    region: process.env.AWS_REGION || 'us-east-1',
});

const bucket = 'photosphere-assets';
const key = 'sets/4defc344-213e-4d49-ae2f-061cfcc2d4bd/asset/2d4af611-83d3-4a21-a4a8-1337891f6fd1';

try {
    const result = await s3.headObject({ Bucket: bucket, Key: key }).promise();
    if (!result.LastModified) {
        throw new Error(`LastModified is undefined`);
    }
    console.log({
        contentType: result.ContentType,
        length: result.ContentLength,
        lastModified: result.LastModified,
    });
}
catch (err) {
    if (err.statusCode === 404) {
        console.log(`code=${err.code} message=${err.message} endpoint=${s3.config.endpoint} region=${s3.config.region}`);
    }
    else {
        throw err;
    }
}
