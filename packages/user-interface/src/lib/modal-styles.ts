import { MOBILE_BREAKPOINT_PX } from "./use-is-mobile";

//
// Styles applied to each individual action inside a mobile dialog's action row.
//
export interface IMobileDialogActionChildSx {
    // Fill the width of the stack.
    width: '100%';

    // Comfortable tap height. Material's minimum touch target is 48px.
    minHeight: string;
}

//
// Styles applied to a dialog's action row on a phone. The actions become a full-width stack at the
// bottom of the sheet (the thumb end of the screen) instead of a cramped right-aligned row.
//
export interface IMobileDialogActionsSx {
    // Stack the actions vertically. Reversed because Joy's right-aligned row puts the primary
    // action last, and stacking should leave that primary action on top.
    flexDirection: 'column-reverse';

    // Space between the stacked actions.
    gap: string;

    // The stack spans the sheet.
    width: '100%';

    // Every action fills the width, giving a large, unmissable tap target.
    '& > *': IMobileDialogActionChildSx;
}

//
// Styles applied to a dialog's title on a phone. The title stays put while the body scrolls, so it
// is always clear which sheet is open.
//
export interface IMobileDialogTitleSx {
    // Pin the title to the top of the scrolling sheet.
    position: 'sticky';

    // Pinned against the top edge of the sheet's padding box.
    top: string;

    // Sit above the scrolling content.
    zIndex: number;

    // Opaque, so content scrolling underneath does not show through.
    backgroundColor: string;

    // Larger than the desktop title: on a small screen the sheet's heading is the main landmark.
    fontSize: string;

    // Breathing room under the heading.
    paddingBottom: string;
}

//
// The grab handle drawn at the top of a mobile sheet: the small horizontal bar that signals the
// panel came up from the bottom edge.
//
export interface ISheetHandleSx {
    // Drawn with a pseudo-element, so no markup changes are needed across twenty dialogs.
    content: '""';

    // Block, so it can be centred with auto margins.
    display: 'block';

    // Handle width.
    width: string;

    // Handle thickness.
    height: string;

    // Fully rounded ends.
    borderRadius: string;

    // Muted, so it reads as an affordance rather than as content.
    backgroundColor: string;

    // Centred, with space below it before the title.
    margin: string;
}

//
// The sheet treatment applied to a dialog on a phone-sized screen: the dialog leaves the middle of
// the screen and becomes a bottom sheet, anchored to the bottom edge, spanning the full width, with
// a grab handle, a sticky title, and full-width actions at the thumb end.
//
export interface IMobileSheetSx {
    // Anchored to the viewport rather than centred within it.
    position: 'fixed';

    // Pinned to the bottom edge.
    top: 'auto';

    // Flush with the bottom of the screen.
    bottom: string;

    // Flush with the left edge.
    left: string;

    // Flush with the right edge.
    right: string;

    // Joy centres its dialog with a translate; the sheet is positioned directly, so that is undone.
    transform: 'none';

    // Span the screen, overriding the desktop min/max widths.
    width: '100vw';

    // Overrides the desktop minimum width.
    minWidth: '100vw';

    // Overrides the desktop maximum width.
    maxWidth: '100vw';

    // Tall enough to be useful, short enough to leave the screen behind it partly visible, and
    // never running under the status bar.
    maxHeight: string;

    // Rounded at the top only, because the bottom edge runs off the screen.
    borderRadius: string;

    // Roomy padding on the sides and top.
    padding: string;

    // Bottom padding clears the system navigation bar / home indicator.
    paddingBottom: string;

    // The grab handle.
    '&::before': ISheetHandleSx;

    // The sticky, larger title.
    '& .MuiDialogTitle-root': IMobileDialogTitleSx;

    // Full-width stacked actions.
    '& .MuiDialogActions-root': IMobileDialogActionsSx;
}

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

    // The bottom-sheet treatment, applied only below the mobile breakpoint. The keys above describe
    // the desktop dialog; this block overrides them on a phone.
    [mobileMediaQuery: string]: string | IMobileSheetSx;
}

//
// Gap (in pixels) kept between a modal dialog and each edge of the viewport so
// the dialog never touches or overflows the screen edges on small form factors.
//
const VIEWPORT_GAP_PX = 16;

//
// The media query under which a dialog is presented as a bottom sheet rather than a centred dialog.
// Keyed off the same breakpoint as `useIsMobile`, so the CSS and the JavaScript agree on where
// "mobile" starts.
//
export const MOBILE_SHEET_MEDIA_QUERY = `@media (max-width: ${MOBILE_BREAKPOINT_PX - 1}px)`;

//
// Builds the bottom-sheet treatment used on phone-sized screens. A centred dialog is a desktop
// idiom: it wastes the width, strands its actions in the middle of the screen away from the thumb,
// and squeezes its content between two margins. A sheet anchored to the bottom edge uses the full
// width, puts the actions where the thumb already rests, and reads as native on a phone.
//
function mobileSheetSx(): IMobileSheetSx {
    return {
        position: 'fixed',
        top: 'auto',
        bottom: '0px',
        left: '0px',
        right: '0px',
        transform: 'none',
        width: '100vw',
        minWidth: '100vw',
        maxWidth: '100vw',
        maxHeight: 'calc(92vh - env(safe-area-inset-top))',
        borderRadius: '20px 20px 0px 0px',
        padding: '12px 20px 0px 20px',
        paddingBottom: 'calc(20px + env(safe-area-inset-bottom))',
        '&::before': {
            content: '""',
            display: 'block',
            width: '36px',
            height: '4px',
            borderRadius: '2px',
            backgroundColor: 'var(--joy-palette-neutral-outlinedBorder)',
            margin: '0px auto 12px auto',
        },
        '& .MuiDialogTitle-root': {
            position: 'sticky',
            top: '0px',
            zIndex: 2,
            backgroundColor: 'var(--joy-palette-background-surface)',
            fontSize: 'var(--joy-fontSize-xl)',
            paddingBottom: '12px',
        },
        '& .MuiDialogActions-root': {
            flexDirection: 'column-reverse',
            gap: '8px',
            width: '100%',
            '& > *': {
                width: '100%',
                minHeight: '48px',
            },
        },
    };
}

//
// Builds a responsive `sx` for a MUI Joy `ModalDialog`. On a wide screen the dialog keeps its
// comfortable desktop size (between `minWidth` and `maxWidth`), centred, with its actions in a
// right-aligned row. On a phone the same dialog becomes a bottom sheet: full width, anchored to the
// bottom edge, with a grab handle, a sticky title, and full-width actions under the thumb.
//
// Both forms are expressed in CSS (a media query) rather than through a JavaScript breakpoint, so a
// dialog adapts as the viewport changes without re-rendering, and every dialog in the app picks up
// the mobile treatment from this one function.
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
        // On a phone, drop the centred dialog and present a bottom sheet instead.
        [MOBILE_SHEET_MEDIA_QUERY]: mobileSheetSx(),
    };
}
