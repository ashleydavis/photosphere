import * as fs from "fs-extra";
import { test, expect } from '@playwright/test';
const { describe } = test; 

const FRONTEND_URL = "http://localhost:1234";

describe("frontend tests", () => {

    test("can upload asset", async ({ page }) => {
        await page.goto(`${FRONTEND_URL}/upload`);

        await fs.remove("../backend/uploads");
        await fs.ensureDir("../backend/uploads");
        
        // https://www.programsbuzz.com/article/playwright-upload-file
        await page.setInputFiles("#upload-file-input", "../backend/test/test-assets/1.jpeg");

        const uploadedFiles = await fs.readdir("../backend/uploads");
        expect(uploadedFiles.length === 1);
    });

});