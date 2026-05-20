//
// Form state for the add/edit secret dialog and helpers for converting between
// form state and the raw vault value string.
//
// Storage model (see Managing-Secrets.md):
// - s3-credentials: vault value is JSON containing region, accessKeyId,
//   secretAccessKey and an optional endpoint.
// - encryption-key: vault value is the raw private-key PEM. The public key
//   is derived on demand and is not stored.
// - api-key: vault value is the raw API key string.
//

//
// Form state for the add/edit secret dialog.
//
export interface ISecretFormState {
    // The secret name (used as the vault key).
    name: string;

    // The category of secret.
    type: string;

    // S3 credentials fields.
    s3Endpoint: string;
    s3Region: string;
    s3AccessKeyId: string;
    s3SecretAccessKey: string;

    // Encryption key fields.
    privateKeyPem: string;
    publicKeyPem: string;

    // API key field.
    apiKey: string;
}

//
// Returns an empty form state.
//
export function emptyFormState(): ISecretFormState {
    return {
        name: '',
        type: 's3-credentials',
        s3Endpoint: '',
        s3Region: '',
        s3AccessKeyId: '',
        s3SecretAccessKey: '',
        privateKeyPem: '',
        publicKeyPem: '',
        apiKey: '',
    };
}

//
// Serialises the type-specific fields from form state to a vault value string.
//
export function buildValueJson(form: ISecretFormState): string {
    if (form.type === 's3-credentials') {
        const obj: Record<string, string> = {
            region: form.s3Region.trim(),
            accessKeyId: form.s3AccessKeyId.trim(),
            secretAccessKey: form.s3SecretAccessKey.trim(),
        };
        if (form.s3Endpoint) {
            obj.endpoint = form.s3Endpoint.trim();
        }
        return JSON.stringify(obj);
    }
    if (form.type === 'encryption-key') {
        return form.privateKeyPem;
    }
    return form.apiKey.trim();
}

//
// Populates type-specific form fields from a raw vault value string.
//
export function applyValueJson(form: ISecretFormState, valueJson: string): ISecretFormState {
    if (form.type === 'encryption-key') {
        return { ...form, privateKeyPem: valueJson, publicKeyPem: '' };
    }
    if (form.type === 'api-key') {
        return { ...form, apiKey: valueJson };
    }
    const parsed = JSON.parse(valueJson);
    return {
        ...form,
        s3Endpoint: parsed.endpoint ?? '',
        s3Region: parsed.region ?? '',
        s3AccessKeyId: parsed.accessKeyId ?? '',
        s3SecretAccessKey: parsed.secretAccessKey ?? '',
    };
}
