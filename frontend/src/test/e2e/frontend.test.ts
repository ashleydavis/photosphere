import * as fs from "fs-extra";
import { test, expect } from '@playwright/test';
const { describe } = test; 

const FRONTEND_URL = "http://localhost:1234";

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

        //
        // Check that the uploaded assets appears in the gallery.
        //
        await page.goto(`${FRONTEND_URL}/cloud`);

        // await sleep(5000); //fio:
            
        const galleryThumb = page.getByTestId("gallery-thumb");
        await expect(galleryThumb).toHaveCount(1);
        await expect(galleryThumb).toBeVisible();
    });

});