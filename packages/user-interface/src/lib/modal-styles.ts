//
// The responsive `sx` values produced for a MUI Joy `ModalDialog`. This is kept
// as a concrete interface (rather than the broad Joy `SxProps` union) so the
// individual values can be asserted directly in unit tests. The shape is still
// assignable to a `ModalDialog`'s `sx` prop when spread into it.
//
export interface IResponsiveModalSx {
    // Minimum dialog width; shrinks below the desktop minimum on narrow (mobile) viewports.
    minWidth: string;

    // Maximum dialog width; never exceeds the viewport width.
    maxWidth: string;

    // Maximum dialog height; keeps the dialog within the visible viewport.
    maxHeight: string;

    // Enables vertical scrolling of the dialog body when the content is tall.
    overflowY: 'auto';

    // Prevents horizontal scrolling of the dialog body.
    overflowX: 'hidden';
}

//
// Gap (in pixels) kept between a modal dialog and each edge of the viewport so
// the dialog never touches or overflows the screen edges on small form factors.
//
const VIEWPORT_GAP_PX = 16;

//
// Builds a responsive `sx` for a MUI Joy `ModalDialog` that works on both
// desktop and mobile form factors. On wide screens the dialog keeps its
// comfortable desktop size (between `minWidth` and `maxWidth`); on a narrow
// mobile viewport it shrinks to fit instead of overflowing horizontally. The
// height is capped to the visible viewport (minus the safe-area insets used
// elsewhere in the app) and the body scrolls internally so tall dialogs stay
// fully reachable. Clamping uses CSS `min()`/`calc()` against the viewport, so
// the same value adapts to any screen width without a JavaScript breakpoint.
//
export function responsiveModalSx(minWidth: number, maxWidth: number): IResponsiveModalSx {
    return {
        // Shrink below the desktop minimum when the viewport is too narrow to hold it.
        minWidth: `min(${minWidth}px, calc(100vw - ${VIEWPORT_GAP_PX * 2}px))`,
        // Cap at the desktop maximum, but never exceed the viewport width.
        maxWidth: `min(${maxWidth}px, calc(100vw - ${VIEWPORT_GAP_PX * 2}px))`,
        // Never taller than the visible viewport, accounting for mobile safe-area insets.
        maxHeight: `calc(100vh - env(safe-area-inset-top) - env(safe-area-inset-bottom) - ${VIEWPORT_GAP_PX * 2}px)`,
        // Scroll vertically when the content is tall; never scroll horizontally.
        overflowY: 'auto',
        overflowX: 'hidden',
    };
}
