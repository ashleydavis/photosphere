import * as fs from "fs-extra";
import { test, expect } from '@playwright/test';
const { describe } = test; 

const FRONTEND_URL = "http://localhost:8080";
const BACKEND_URL = "http://localhost:3000";

describe("frontend tests", () => {

    function sleep(ms: number): Promise<void> {
        return new Promise<void>(resolve => {
            setTimeout(resolve, ms);
        });
    }

    test("can upload asset and then see the asset in the gallery", async ({ page }) => {

        const apiKey = "testing-token";

        await page.goto(`${FRONTEND_URL}/upload`);
        
        //
        // Uploads an image.
        //
        // https://www.programsbuzz.com/article/playwright-upload-file
        await page.setInputFiles("#upload-file-input", "../backend/test/test-assets/1.jpeg");

        let uploadedFiles: string[];

        // 
        // Wait for assets to upload.
        //
        while (true) {
            await sleep(1); //TODO: Should wait until progress spinner has hidden.

            const uploadDir = "../backend/files/collections/test-collection/display";
            if (!fs.existsSync(uploadDir)) {
                continue;
            }
    
            uploadedFiles = (await fs.readdir(uploadDir))
                .filter(file => !file.endsWith(".info")); // Remove info files.
            if (uploadedFiles.length > 0) {
                break;
            }
        }
        
        expect(uploadedFiles.length).toBe(1);

        const [ assetId ] = uploadedFiles;

        //
        // Check that the uploaded assets appears in the gallery.
        //
        await page.goto(`${FRONTEND_URL}/cloud`);
            
        const galleryThumb = page.getByTestId("gallery-thumb");
        await expect(galleryThumb).toHaveCount(1);
        await expect(galleryThumb).toBeVisible();
        const thumbSrc = await galleryThumb.getAttribute("src");
        expect(thumbSrc!.startsWith("blob:")).toBeTruthy()

        const fullsizeAsset = page.getByTestId("fullsize-asset");
        await expect(fullsizeAsset).toHaveCount(0);

        const infoAssetId = page.getByTestId("asset-id");
        await expect(infoAssetId).toHaveCount(0);

        //
        // Open fullscreen photo modal.
        //
        await galleryThumb.click();
        await expect(fullsizeAsset).toHaveCount(1);
        await expect(fullsizeAsset).toBeVisible();
        const fullSizeSrc = await fullsizeAsset.getAttribute("src");
        expect(fullSizeSrc!.startsWith("blob:")).toBeTruthy()

        //
        // Open photo info.
        //
        const openInfoButton = page.getByTestId("open-info-button");
        await openInfoButton.click();
        await expect(infoAssetId).toHaveCount(1);
        await expect(infoAssetId).toBeVisible();
        await expect(infoAssetId).toHaveText(assetId);
    });

});