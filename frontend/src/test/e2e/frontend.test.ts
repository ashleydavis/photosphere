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

        // const apiKey = "1234";

        // page.on("dialog", async dialog => {
        //     // Enters the API key into the prompt.
        //     await dialog.accept(apiKey);
        // });

        await page.goto(`${FRONTEND_URL}/upload`);

        //
        // Clear uploaded assets.
        //
        await fs.remove("../backend/files");
        await fs.ensureDir("../backend/files/original");
        await fs.ensureDir("../backend/files/thumb");
        await fs.ensureDir("../backend/files/display");
        
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
    
            uploadedFiles = await fs.readdir("../backend/files/original");
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
        await expect(galleryThumb).toHaveAttribute("src", `${BACKEND_URL}/thumb?id=${assetId}`);

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
        await expect(fullsizeAsset).toHaveAttribute("src", `${BACKEND_URL}/display?id=${assetId}`);

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