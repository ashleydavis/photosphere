# Plan: Silky Smooth Gallery Scrolling

## Context

The gallery uses TanStack React Virtual for row-level virtualization with a custom scrollbar. The current implementation has a few characteristics that cause visible roughness:

1. **`overscan: 0`** — Only rows fully inside the viewport are rendered. On fast scrolling, rows pop into view visibly, causing a "stamping" effect.
2. **Scroll event → `setScrollTop` → React re-render** — Every native scroll event triggers a React state update, which can cause mid-frame jank as the layout pipeline is interrupted.
3. **Keyboard navigation uses `behavior: "instant"`** — Arrow/Page key navigation jumps rather than scrolling smoothly.

---

## Changes

### 1. Increase virtualizer overscan (highest impact, lowest risk)

**File:** `packages/user-interface/src/components/gallery-layout.tsx` — around line 223

**Reason:** Pre-rendering rows before they enter the viewport means the GPU composites already-painted content rather than triggering a new render+paint cycle mid-scroll, eliminating the "stamping" pop-in effect on fast scrolling.

Change `overscan: 0` to `overscan: 3`:

```typescript
const rowVirtualizer = useVirtualizer({
    count: layout?.rows.length || 0,
    getScrollElement: () => containerRef.current,
    estimateSize: (i) => layout?.rows[i].height || 0,
    overscan: 3,   // was 0
});
```

---

### 2. Throttle scroll state updates with `requestAnimationFrame`

**File:** `packages/user-interface/src/components/gallery-layout.tsx` — `onScroll` handler, around line 175

**Reason:** The `scroll` event fires up to 4–8 times per frame, and each call schedules a React re-render; throttling to one update per animation frame keeps React's work aligned with the browser's paint cycle, freeing the main thread for smooth compositing.

```typescript
const rafId = useRef<number | undefined>(undefined);

function onScroll() {
    if (rafId.current !== undefined) {
        return;
    }
    rafId.current = requestAnimationFrame(() => {
        setScrollTop(container.scrollTop);
        rafId.current = undefined;
    });
}
```

Clean up in the `return` of the effect:

```typescript
return () => {
    container.removeEventListener('scroll', onScroll);
    window.removeEventListener("keydown", onKeyDown);
    if (rafId.current !== undefined) {
        cancelAnimationFrame(rafId.current);
    }
};
```

---

### ~~3. Smooth keyboard navigation~~ (reverted)

**Original reasoning (incorrect):** `behavior: "smooth"` hands easing off to the browser's compositor-driven scroll animation, which runs off the main thread and produces the same fluid motion as trackpad momentum scrolling.

**Why it failed:** While `behavior: "smooth"` does use compositor-driven animation for a single programmatic scroll call, the plan failed to account for key-repeat — the OS fires keydown events faster than each smooth animation can complete. Each event starts a new animation that fights the previous one, causing jerkiness. All keyboard scrolling stays as `behavior: "instant"`.

---

## Verification

1. Start the dev frontend: `cd apps/dev-frontend && bun run start`
2. Start backend: `cd apps/backend && bun run dev`
3. Open the gallery and fast-scroll through many photos — rows should appear without pop-in (change 1)
4. Open DevTools Performance tab and record a scroll session — check there is ≤1 React re-render per animation frame (change 2)
5. Use arrow keys and page keys — scrolling should animate smoothly (change 3)
6. Drag the custom scrollbar rapidly — should still feel fast (no regression)
