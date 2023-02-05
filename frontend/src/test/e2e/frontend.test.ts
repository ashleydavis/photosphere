import * as fs from "fs-extra";
import { test, expect } from '@playwright/test';
const { describe } = test; 

const FRONTEND_URL = "http://localhost:1234";
const BACKEND_URL = "http://localhost:3000";

describe("frontend tests", () => {

    function sleep(ms: number): Promise<void> {
        return new Promise<void>(resolve => {
            setTimeout(resolve, ms);
        });
    }

    test("can upload asset and then see the asset in the gallery", async ({ page }) => {

        await page.goto(`${FRONTEND_URL}/upload`);

        //
        // Clear uploaded assets.
        //
        await fs.remove("../backend/uploads");
        await fs.ensureDir("../backend/uploads");
        await fs.remove("../backend/thumbs");
        await fs.ensureDir("../backend/thumbs");
        
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
    
            uploadedFiles = await fs.readdir("../backend/uploads");
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

        //
        // Open fullscreen photo modal.
        //
        await galleryThumb.click();
        await expect(fullsizeAsset).toHaveCount(1);
        await expect(fullsizeAsset).toBeVisible();
        await expect(fullsizeAsset).toHaveAttribute("src", `${BACKEND_URL}/asset?id=${assetId}`);

        //TODO:
        // const photoInfoHeader = page.getByTestId("info-header");
        // await expect(photoInfoHeader).toHaveCount(0);

        // //
        // // Open photo info.
        // //
        // const openInfoButton = page.getByTestId("open-info-button");
        // await openInfoButton.click();

        // await expect(photoInfoHeader).toHaveCount(1);
        // await expect(photoInfoHeader).toBeVisible();
    });

});