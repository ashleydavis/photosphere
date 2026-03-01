import { test, expect, _electron as electron } from '@playwright/test';
import { join } from 'path';
import { existsSync, readdirSync } from 'fs';

// Executable name - hardcoded in electron-builder config
const executableName = 'photosphere';
// Product name - used for macOS .app bundle name
const productName = 'Photosphere';

test.describe('Smoke Tests', () => {
  test('should navigate to About page and verify content', async () => {
    // Determine the built app path based on platform
    const releaseDir = join(__dirname, '../release');
    let executablePath: string;
    
    if (process.platform === 'win32') {
      // Windows: executableName.exe
      executablePath = join(releaseDir, 'win-unpacked', `${executableName}.exe`);
    } else if (process.platform === 'darwin') {
      // macOS: executableName.app/Contents/MacOS/executableName
      // Check for mac-arm64 (ARM64) or mac (Intel) directory
      const macDir = existsSync(join(releaseDir, 'mac-arm64')) 
        ? join(releaseDir, 'mac-arm64')
        : join(releaseDir, 'mac');
      executablePath = join(macDir, `${executableName}.app`, 'Contents', 'MacOS', executableName);
    } else {
      // Linux: executableName
      executablePath = join(releaseDir, 'linux-unpacked', executableName);
    }

    // Check if executable exists
    const exists = existsSync(executablePath);
    console.log(`Executable name: ${executableName}`);
    console.log(`Executable path: ${executablePath}`);
    console.log(`Executable exists: ${exists}`);
    
    // If executable doesn't exist, list directory contents to help debug
    if (!exists) {
      const parentDir = join(executablePath, '..');
      console.log(`Checking parent directory: ${parentDir}`);
      console.log(`Parent directory exists: ${existsSync(parentDir)}`);
      if (existsSync(parentDir)) {
        try {
          const contents = readdirSync(parentDir);
          console.log(`Contents of ${parentDir}:`);
          console.log(contents.join(', '));
        } catch (err) {
          console.error(`Error reading directory ${parentDir}:`, err);
        }
      }
      // Also check if the .app bundle exists
      if (process.platform === 'darwin') {
        const appPath = join(executablePath, '..', '..', '..');
        console.log(`Checking .app bundle: ${appPath}`);
        console.log(`App bundle exists: ${existsSync(appPath)}`);
        if (existsSync(appPath)) {
          try {
            const appContents = readdirSync(appPath);
            console.log(`Contents of .app bundle: ${appContents.join(', ')}`);
          } catch (err) {
            console.error(`Error reading .app bundle:`, err);
          }
        }
      }
      throw new Error(`Executable not found: ${executableName}\nExpected path: ${executablePath}\nPlease run 'bun run build' first.`);
    }

    // Launch the built Electron app
    // For Linux, we need to run from the unpacked directory
    let cwd: string;
    if (process.platform === 'linux') {
      cwd = join(releaseDir, 'linux-unpacked');
    } else if (process.platform === 'win32') {
      cwd = join(releaseDir, 'win-unpacked');
    } else {
      // macOS: find the mac directory (could be mac-arm64 for ARM64 or mac for Intel)
      const macDir = existsSync(join(releaseDir, 'mac-arm64')) 
        ? join(releaseDir, 'mac-arm64')
        : join(releaseDir, 'mac');
      cwd = join(macDir, `${executableName}.app`, 'Contents', 'MacOS');
    }
    
    console.log(`Working directory: ${cwd}`);
    
    let electronApp;
    try {
      electronApp = await electron.launch({
        executablePath,
        cwd,
        args: ['--no-sandbox'],
        timeout: 60_000,
      });
    } catch (error) {
      console.error('Failed to launch Photosphere:', error);
      throw new Error(`Failed to launch Photosphere: ${error}\nExecutable: ${executablePath}\nWorking directory: ${cwd}`);
    }

    // Get the first window
    const window = await electronApp.firstWindow();
    
    // Wait for the page to load
    await window.waitForLoadState('domcontentloaded');

    // Verify "Photosphere is developed by" text is NOT yet visible
    await expect(window.getByText('Photosphere is developed by')).not.toBeVisible();

    // Find and click the About link
    const aboutLink = window.getByRole('link', { name: /about/i });
    await expect(aboutLink).toBeVisible();
    await aboutLink.click();

    // Verify "Photosphere is developed by" text appears
    await expect(window.getByText('Photosphere is developed by')).toBeVisible();

    // Close the app
    await electronApp.close();
  });
});
