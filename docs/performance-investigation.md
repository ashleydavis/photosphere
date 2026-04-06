# Gallery Loading Performance Investigation

## The Problem

The gallery renders at ~2fps while loading a database of 100k assets. It should stay close to 60fps during loading — assets should appear progressively while the UI remains responsive.

## How to Measure FPS

FPS logging is built in. From the repo root directory run the app with:

```
bun run dev:fps
```

This sets `FPS_LOGGING=1`, which causes `main.ts` to write one CSV row per second to `/tmp/photosphere-fps.csv` (columns: `timestamp`, `fps`). The database opens automatically. Let it run for ~2 minutes, kill it, then compute the average:

```
awk -F, 'NR>1 {sum+=$2; count++} END {print "avg fps:", sum/count}' /tmp/photosphere-fps.csv
```

FPS is measured in `fps.tsx` using a `requestAnimationFrame` loop and sent to the main process via `window.electronAPI.sendFps(fps)`.

## What Has Been Tried (All Reverted)

Several optimisations were attempted but none fixed the 2fps issue:

1. **Incremental layout** (`gallery-layout-context.tsx`): Changed `onNewItems` handler from full `computePartialLayout(undefined, sortedItems(), ...)` rebuild to `computePartialLayout(prev, newItems, ...)` — appending only new items. Correct approach but didn't fix FPS.

2. **`startTransition`** (`gallery-layout-context.tsx`): Wrapped `setLayout` in `startTransition`. Didn't help — functional updaters still run synchronously; only the render is deferred.

3. **`requestAnimationFrame` throttling** (`gallery-layout-context.tsx`): Buffered incoming items and processed at most once per frame. Didn't fix 2fps.

4. **Skipping `applySort` on new items** (`gallery-context.tsx`): `_onNewItems` calls `applySort(allSearchedItems, sorting)` on every batch — O(n log n) growing to 100k items. Replaced with O(k) append. Didn't fix 2fps.

## Current State of the Code

`gallery-context.tsx` and `gallery-layout-context.tsx` have been reverted to their pre-optimisation state. The FPS measurement infrastructure is the only new code present:

- `packages/electron-defs/src/lib/electron-api.ts` — `sendFps` added to `IElectronAPI`
- `apps/desktop/src/preload.ts` — `sendFps` exposed via `ipcRenderer.send('fps-measurement', fps)`
- `apps/desktop/src/main.ts` — `ipcMain.on('fps-measurement', ...)` writes to `/tmp/photosphere-fps.csv` when `FPS_LOGGING=1`
- `apps/desktop/package.json` — `dev:fps` script added
- `packages/user-interface/src/components/fps.tsx` — `requestAnimationFrame` loop added to measure and send FPS

Key files to understand the loading pipeline:

- `packages/user-interface/src/context/gallery-context.tsx` — `_onNewItems()` (~line 440): calls `applySort` on ALL items every batch, then `buildItemsIndex`, then `setTime(Date.now())`
- `packages/user-interface/src/context/gallery-layout-context.tsx` — `onNewItems` subscription (~line 143): calls `rebuildLayout()` → `computePartialLayout(undefined, sortedItems(), ...)`
- `packages/user-interface/src/lib/create-layout.ts` — `computePartialLayout()`: supports incremental append when passed an existing layout
- `packages/user-interface/src/components/gallery-layout.tsx` — gallery renderer using TanStack Virtual

## Suspected Bottlenecks

None of the tried fixes helped, which suggests the real bottleneck is in rendering rather than computation. Top candidates:

1. **TanStack Virtual O(n) work**: `useVirtualizer` with `estimateSize: (i) => layout?.rows[i].height` — when `count` grows, TanStack Virtual may rebuild its cumulative-height offset array for all rows on every update.

2. **`setTime(Date.now())` cascading re-renders**: Called on every batch in `_onNewItems`, this triggers a state update in `gallery-context` that may cause all consumers to re-render.

3. **React reconciliation cost**: Every `setLayout` re-renders the gallery. If visible row/item components aren't memoised, React may destroy and recreate DOM nodes on every update.

## Suggested Next Steps

1. Use `bun run dev:fps` to get a baseline average FPS, then measure again after each change.
2. Profile with Chrome DevTools (`Developer → Toggle Developer Tools` in the Electron menu) — record a Performance trace during loading to see exactly where time is spent.
3. Investigate whether TanStack Virtual is the bottleneck by temporarily replacing it with a plain non-virtualised list and comparing FPS.
4. Investigate `setTime(Date.now())` — try removing or throttling it and measure the effect.
