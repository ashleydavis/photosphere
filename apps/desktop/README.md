# Photosphere Desktop App

The Electron desktop application for Photosphere. This is the cross-platform desktop build that allows you to manage your digital media database locally on Windows, macOS, and Linux.

## Project Structure

```
desktop/
├── src/
│   ├── main.ts                              # Electron main process
│   ├── preload.ts                           # Preload script
│   ├── worker.ts                            # Worker process
│   ├── rest-api-worker.ts                   # REST API worker process
│   └── lib/
│       ├── worker-backend-electron-main.ts   # Electron main process worker backend
│       └── worker-init.ts                   # Worker initialization utilities
├── bundle/                                  # Bundled output
│   ├── main.js
│   ├── preload.js
│   ├── worker.js
│   ├── rest-api-worker.js
│   ├── file-scanner.worker.js               # From file-scanner package
│   ├── hash.worker.js                       # From file-hasher package
│   └── frontend/                            # Bundled frontend from desktop-frontend
├── release/                                 # Distribution builds
├── tests/                                   # Playwright tests
├── playwright.config.ts                     # Playwright configuration
├── package.json
└── tsconfig.json
```

## Getting Started

### Development

#### Running in Development

The desktop app requires both the desktop app and the frontend to be bundled. You need to bundle the frontend from `apps/desktop-frontend` first, then bundle and run the desktop app.

**Workflow:**

```bash
# First, bundle the frontend
cd apps/desktop-frontend
bun run bundle  # Bundles frontend to ../desktop/bundle/frontend

# Then run the desktop app (dev script bundles automatically)
cd ../desktop
bun run dev    # Bundles desktop app and launches Electron with dev tools open
```

This will:
1. Bundle the frontend from `apps/desktop-frontend` to `apps/desktop/bundle/frontend`
2. Bundle the main process, preload script, and workers
3. Launch Electron with dev tools open

#### Building for Production

```bash
# First, bundle the frontend
cd apps/desktop-frontend
bun run bundle  # Bundles frontend to ../desktop/bundle/frontend

# Then build the desktop app
cd ../desktop
bun run build
```

This creates platform-specific installers in `apps/desktop/release/`:
- **macOS**: `.dmg` or `.zip`
- **Windows**: `.exe` (NSIS installer) or `.zip`
- **Linux**: `.deb` or `.zip`

## Testing

### Smoke Tests

Run Playwright smoke tests:

```bash
bun run test:smoke
```

Tests verify:
- App launches successfully
- Basic UI interactions
- File scanning functionality

## Production Builds

### Platform-Specific Builds

Build for specific platforms:

```bash
# macOS
bun run build -- --mac

# Windows
bun run build -- --win

# Linux
bun run build -- --linux
```

### Windows Build Requirements

On Windows, electron-builder downloads the `winCodeSign` tool which contains macOS files with symbolic links. Windows requires administrator privileges to create symbolic links, which can cause build failures.

**Workaround:** Pre-download and extract the winCodeSign archive to avoid the symlink extraction error:

```powershell
cd apps/desktop
bun run setup-electron-builder
```

Or run directly:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup-electron-builder.ps1
```

This script:
- Downloads the winCodeSign archive from GitHub
- Extracts it to the location electron-builder expects (`%LOCALAPPDATA%\electron-builder\Cache\winCodeSign\winCodeSign-2.6.0\`)
- Skips symlinks during extraction (no admin privileges needed)
- Only needs to be run once

After running this script, `bun run build` will work without symlink extraction errors. The script is idempotent - it will skip if the cache already exists.

**Note:** This workaround is needed because electron-builder downloads winCodeSign for all Windows builds, regardless of whether code signing is configured. GitHub Actions Windows runners work because they have Developer Mode enabled or run with elevated privileges.

### Code Signing

Configure code signing in `package.json`:

```json
{
  "build": {
    "mac": {
      "identity": "Developer ID Application: Your Name"
    },
    "win": {
      "certificateFile": "path/to/certificate.pfx"
    }
  }
}
```

