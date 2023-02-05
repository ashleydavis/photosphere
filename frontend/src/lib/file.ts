
//
// Loads a file to a data URL (base64 encoded data).
//
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/Data_URLs
//
export function loadFileToDataURL(file: File | Blob): Promise<string> { 
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
