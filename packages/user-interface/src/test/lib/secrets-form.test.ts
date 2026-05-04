import { applyValueJson, buildValueJson, emptyFormState } from "../../lib/secrets-form";

describe('secrets-form', () => {

    describe('applyValueJson', () => {

        test('s3-credentials populates fields from JSON value', () => {
            const baseForm = { ...emptyFormState(), type: 's3-credentials' };
            const valueJson = JSON.stringify({
                endpoint: 'https://s3.example.com',
                region: 'us-east-1',
                accessKeyId: 'AKIA...',
                secretAccessKey: 'SECRET',
            });

            const result = applyValueJson(baseForm, valueJson);

            expect(result.s3Endpoint).toBe('https://s3.example.com');
            expect(result.s3Region).toBe('us-east-1');
            expect(result.s3AccessKeyId).toBe('AKIA...');
            expect(result.s3SecretAccessKey).toBe('SECRET');
        });

        test('encryption-key uses the raw value as the private key PEM', () => {
            const baseForm = { ...emptyFormState(), type: 'encryption-key' };
            const rawPem = '-----BEGIN PRIVATE KEY-----\nMIIE...\n-----END PRIVATE KEY-----\n';

            const result = applyValueJson(baseForm, rawPem);

            expect(result.privateKeyPem).toBe(rawPem);
            expect(result.publicKeyPem).toBe('');
        });

        test('api-key uses the raw value as the API key', () => {
            const baseForm = { ...emptyFormState(), type: 'api-key' };
            const rawKey = 'sk-1234567890abcdef';

            const result = applyValueJson(baseForm, rawKey);

            expect(result.apiKey).toBe(rawKey);
        });
    });

    describe('buildValueJson', () => {

        test('s3-credentials returns JSON with all four fields when endpoint is set', () => {
            const form = {
                ...emptyFormState(),
                type: 's3-credentials',
                s3Endpoint: 'https://s3.example.com',
                s3Region: 'us-east-1',
                s3AccessKeyId: 'AKIA...',
                s3SecretAccessKey: 'SECRET',
            };

            const valueJson = buildValueJson(form);
            const parsed = JSON.parse(valueJson);

            expect(parsed).toEqual({
                endpoint: 'https://s3.example.com',
                region: 'us-east-1',
                accessKeyId: 'AKIA...',
                secretAccessKey: 'SECRET',
            });
        });

        test('s3-credentials omits endpoint when empty', () => {
            const form = {
                ...emptyFormState(),
                type: 's3-credentials',
                s3Endpoint: '',
                s3Region: 'us-east-1',
                s3AccessKeyId: 'AKIA...',
                s3SecretAccessKey: 'SECRET',
            };

            const valueJson = buildValueJson(form);
            const parsed = JSON.parse(valueJson);

            expect(parsed).toEqual({
                region: 'us-east-1',
                accessKeyId: 'AKIA...',
                secretAccessKey: 'SECRET',
            });
            expect(parsed.endpoint).toBeUndefined();
        });

        test('encryption-key returns the private key PEM verbatim', () => {
            const rawPem = '-----BEGIN PRIVATE KEY-----\nMIIE...\n-----END PRIVATE KEY-----\n';
            const form = {
                ...emptyFormState(),
                type: 'encryption-key',
                privateKeyPem: rawPem,
                publicKeyPem: 'public-should-not-be-stored',
            };

            const result = buildValueJson(form);

            expect(result).toBe(rawPem);
        });

        test('api-key returns the API key verbatim', () => {
            const rawKey = 'sk-1234567890abcdef';
            const form = {
                ...emptyFormState(),
                type: 'api-key',
                apiKey: rawKey,
            };

            const result = buildValueJson(form);

            expect(result).toBe(rawKey);
        });
    });
});
