const { Crypto } = require("@peculiar/webcrypto");

//
// Loads a file (or blob) to a data URL (base64 encoded data).
//
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/Data_URLs
//
export function loadDataURL(file: Blob): Promise<string> { 
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.addEventListener('error', () => {
            reject(new Error(`Error reading file.`));
        });

        reader.addEventListener('load', evt => {
            resolve(evt.target!.result as string)
        });
        
        reader.readAsDataURL(file);
    });
}


//
// Loads a file (or blob) to an array buffer.
//
export function loadArrayBuffer(file: Blob): Promise<ArrayBuffer> { 
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.addEventListener('error', () => {
            reject(new Error(`Error reading file.`));
        });

        reader.addEventListener('load', evt => {
            resolve(evt.target!.result as ArrayBuffer)
        });
        
        reader.readAsArrayBuffer(file);
    });
}


//
// Computes a hash for a file or blob of data.
// 
// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/digest
// https://github.com/jsdom/jsdom/issues/1612#issuecomment-663210638
// https://www.npmjs.com/package/@peculiar/webcrypto
// https://github.com/PeculiarVentures/webcrypto-docs/blob/master/README.md
//
export async function computeHash(data: Blob) {

    const crypto = new Crypto();
    const dataBuffer = await loadArrayBuffer(data);
    const hashBuffer = await crypto.subtle.digest('SHA-256', dataBuffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const hashHex = hashArray.map((b) => b.toString(16).padStart(2, '0')).join('');
    return hashHex;
}