# Photosphere Desktop Frontend

The frontend for Photosphere's Electron desktop application. This frontend provides the user interface for the desktop app and communicates with the Electron main process via IPC.

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

## Task Queue

The frontend uses `ElectronTaskQueue` from the desktop package:

```typescript
import { ElectronTaskQueue } from '../desktop/src/task-queue-electron';

const taskQueue = new ElectronTaskQueue(window.electronAPI);
```

The task queue is created as a singleton and used by the shared `App` component from `user-interface`.

## Available Scripts

- `bun run bundle` - Bundle with Bun (outputs to `../desktop/bundle/frontend`)
- `bun run compile` - Type-check TypeScript code

## Configuration

### Bundling

The frontend is bundled using Bun's built-in bundler. The bundle script:
- Bundles `src/index.tsx` to `../desktop/bundle/frontend`
- Targets browser environment
- Includes minification and source maps
- Copies `index.html` to the bundle directory

## Project Structure

```
desktop-frontend/
├── src/
│   ├── index.tsx        # React entry point
│   ├── task-queue.ts    # Task queue setup
│   └── index.css        # Global styles
├── index.html           # HTML template
├── package.json
└── tsconfig.json
```

