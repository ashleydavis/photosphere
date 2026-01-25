# Photosphere Linux Installation

## Contents of this ZIP file

This ZIP file contains the Photosphere application for Linux, including:

- `photosphere` - The main application executable
- `chrome-sandbox` - Sandbox helper binary (requires special permissions)
- `lib/` - Application libraries and resources
- `scripts/fix-sandbox.sh` - Script to fix chrome-sandbox permissions (recommended)

## Installation

1. Extract this ZIP file to your desired location:
   ```bash
   unzip Photosphere-*.zip
   cd Photosphere-*
   ```

2. **IMPORTANT**: Fix the chrome-sandbox permissions before running the application.

   **Option A: Use the provided script (recommended):**
   ```bash
   bash scripts/fix-sandbox.sh
   ```
   
   This script will automatically set the correct permissions. You'll be prompted for your password.

   **Option B: Manual fix:**
   ```bash
   sudo chown root:root chrome-sandbox
   sudo chmod 4755 chrome-sandbox
   ```

3. Run the application:
   ```bash
   ./photosphere
   ```

## Fixing the SUID Sandbox Error

If you see this error when trying to run Photosphere:

```
The SUID sandbox helper binary was found, but is not configured correctly. 
Rather than run without sandboxing I'm aborting now. You need to make sure 
that chrome-sandbox is owned by root and has mode 4755.
```

This means the `chrome-sandbox` file doesn't have the correct permissions. To fix it:

**Easiest method - use the provided script:**
```bash
cd /path/to/Photosphere
bash scripts/fix-sandbox.sh
```

**Or manually:**
1. Navigate to the directory where you extracted Photosphere:
   ```bash
   cd /path/to/Photosphere
   ```

2. Set the ownership to root:
   ```bash
   sudo chown root:root chrome-sandbox
   ```

3. Set the permissions to 4755 (SUID bit):
   ```bash
   sudo chmod 4755 chrome-sandbox
   ```

4. Verify it worked:
   ```bash
   ls -l chrome-sandbox
   ```
   
   The output should show `-rwsr-xr-x` and `root root` as the owner.

5. Try running the application again:
   ```bash
   ./photosphere
   ```

## Why is this needed?

Electron applications on Linux use a security sandbox. The `chrome-sandbox` binary requires special permissions (the SUID bit) to function correctly. The SUID bit only works when the file is owned by root, which is why you need to run the `chown` command with `sudo`.

## Alternative: Use the .deb Package

For automatic installation and permission setup, consider using the `.deb` package instead of the ZIP file. The .deb package automatically fixes permissions during installation, so you don't need to run these commands manually.
