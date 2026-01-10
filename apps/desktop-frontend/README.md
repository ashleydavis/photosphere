# Photosphere Desktop Frontend

The frontend for Photosphere's Electron desktop application. 

## Project Structure

```
desktop-frontend/
├── src/
│   ├── index.tsx                              # React entry point
│   ├── app.tsx                                # Main app component
│   ├── index.css                              # Global styles
│   ├── tailwind.css                           # Tailwind CSS
│   └── lib/
│       ├── task-queue-provider-electron.ts    # Electron task queue provider
│       └── worker-backend-electron-renderer.ts # Electron renderer worker backend
├── index.html                                  # HTML template
├── package.json
├── tsconfig.json
├── vite.config.ts                              # Vite configuration
├── tailwind.config.js                          # Tailwind configuration
└── postcss.config.js                           # PostCSS configuration
```

## Getting Started

### Development

The frontend is bundled and loaded by the Electron desktop app. To run the complete desktop application:

#### Running the Full Desktop Application

**Step 1: Bundle the frontend**

From the `desktop-frontend` directory:

```bash
cd apps/desktop-frontend
bun run bundle  # Bundles frontend to ../desktop/bundle/frontend
```

**Step 2: Bundle and run the desktop app**

From the `desktop` directory:

```bash
cd apps/desktop
bun run bundle  # Bundles desktop app (main, preload, workers)
bun run dev     # Launches Electron with dev tools open
```

**Note:** You must bundle the frontend before running the desktop app, as the desktop app loads the bundled frontend from `apps/desktop/bundle/frontend/index.html`.

### Building for Production

```bash
# Bundle for Electron (outputs to apps/desktop/bundle/frontend)
bun run bundle
```

