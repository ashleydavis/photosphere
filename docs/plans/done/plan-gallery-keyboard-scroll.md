# Plan: Gallery Keyboard Scroll Bindings

## Context

The gallery supports mouse/touch scrolling and a custom scrollbar, but has no keyboard scroll support. This plan adds:
- Arrow Up/Down for fluid smooth scrolling
- Page Up/Down for full-page instant scrolling

---

## Files

| # | File | Change |
|---|------|--------|
| 1 | `packages/user-interface/src/components/gallery-layout.tsx` | Add `keydown` listener to `window` inside existing scroll `useEffect` |

---

## Implementation

In `GalleryLayout` ([gallery-layout.tsx](../../packages/user-interface/src/components/gallery-layout.tsx)), extend the existing `useEffect` (which sets up the `scroll` listener on `containerRef`) to also attach a `keydown` listener on `window`.

The handler skips interception when `document.activeElement` is an `input`, `textarea`, `select`, or `button`, so typing in the search box or other controls is unaffected.

```ts
function onKeyDown(event: KeyboardEvent) {
    const tag = (document.activeElement as HTMLElement)?.tagName?.toLowerCase();
    if (tag === "input" || tag === "textarea" || tag === "select" || tag === "button") {
        return;
    }
    if (event.key === "ArrowDown") {
        event.preventDefault();
        container.scrollBy({ top: 120, behavior: "smooth" });
    }
    else if (event.key === "ArrowUp") {
        event.preventDefault();
        container.scrollBy({ top: -120, behavior: "smooth" });
    }
    else if (event.key === "PageDown") {
        event.preventDefault();
        container.scrollBy({ top: container.clientHeight, behavior: "instant" } as any);
    }
    else if (event.key === "PageUp") {
        event.preventDefault();
        container.scrollBy({ top: -container.clientHeight, behavior: "instant" } as any);
    }
}

window.addEventListener("keydown", onKeyDown);
```

Clean up in the `useEffect` return alongside the existing `scroll` removal:

```ts
return () => {
    container.removeEventListener("scroll", onScroll);
    window.removeEventListener("keydown", onKeyDown);
};
```

The `behavior: "instant" as any` cast follows the existing pattern already used in this file (lines 176 and 299).

### Scroll amounts
- Arrow keys: ±120 px, smooth — fluid feel
- Page Up/Down: ±`container.clientHeight`, instant — crisp full-page jump

---

## Verification

1. Open the gallery page — without clicking, press ArrowDown/ArrowUp → gallery scrolls smoothly.
2. Press PageDown/PageUp → gallery jumps a full page.
3. Click the search box and press arrow keys → characters are typed, gallery does not scroll.
4. Open the asset view drawer and press keys → gallery behind the drawer does not scroll.
