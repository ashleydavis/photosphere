//
// Converts a blob to a PNG blob by drawing it onto a canvas.
// Required because the clipboard API only accepts image/png.
//
export async function convertToPng(blob: Blob): Promise<Blob> {
    const objectUrl = URL.createObjectURL(blob);
    try {
        const img = await new Promise<HTMLImageElement>((resolve, reject) => {
            const image = new Image();
            image.onload = () => resolve(image);
            image.onerror = reject;
            image.src = objectUrl;
        });
        const canvas = document.createElement("canvas");
        canvas.width = img.naturalWidth;
        canvas.height = img.naturalHeight;
        const ctx = canvas.getContext("2d")!;
        ctx.drawImage(img, 0, 0);
        return await new Promise<Blob>((resolve, reject) => {
            canvas.toBlob(pngBlob => {
                if (pngBlob) {
                    resolve(pngBlob);
                }
                else {
                    reject(new Error("Failed to convert image to PNG"));
                }
            }, "image/png");
        });
    }
    finally {
        URL.revokeObjectURL(objectUrl);
    }
}
