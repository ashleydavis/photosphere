//
// Styles applied to each individual action inside a mobile sheet's action row.
//
export interface IMobileDialogActionChildSx {
    // Fill the width of the stack.
    width: '100%';

    // Comfortable tap height. Material's minimum touch target is 48px.
    minHeight: string;
}

//
// Styles applied to a sheet's action row on a phone. The actions become a full-width stack at the
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
// Styles applied to a sheet's title on a phone. The title stays put while the body scrolls, so it
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

    // The sheet content is a flex column, so the handle must not be squashed when the body is tall.
    flexShrink: number;

    // Fully rounded ends.
    borderRadius: string;

    // Muted, so it reads as an affordance rather than as content.
    backgroundColor: string;

    // Centred, with space below it before the title.
    margin: string;
}

//
// Styles applied to the Joy `Drawer`'s content panel: the sheet itself, as opposed to the backdrop
// behind it. Joy sizes a bottom drawer to a fixed fraction of the screen; these values make it hug
// its content instead and give it the sheet's rounded top, padding, handle, title, and actions.
//
export interface IMobileSheetContentSx {
    // Joy's default is `min(100vh, var(--Drawer-verticalSize))`, which forces every sheet to the
    // same tall fraction of the screen. A dialog should be only as tall as its content.
    height: 'auto';

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
// The `sx` values produced for the Joy `Drawer` that presents a dialog as a bottom sheet on a phone.
// Kept as a concrete interface (rather than the broad Joy `SxProps` union) so the individual values
// can be asserted directly in unit tests.
//
export interface IMobileSheetDrawerSx {
    // How long the sheet takes to slide in and out. Joy drives its own slide from this variable.
    '--Drawer-transitionDuration': string;

    // The easing of that slide.
    '--Drawer-transitionFunction': string;

    // Joy derives the inset of a `ModalClose` button from this, so it must match the sheet's own
    // corner radius or the close button sits wrong in the corner.
    '--Drawer-contentRadius': string;

    // The sheet panel itself.
    '& .MuiDrawer-content': IMobileSheetContentSx;

    // Joy's `sx` prop accepts CSS variables and nested selectors only through an index signature.
    // Without this the keys above, which are all one or the other, are not assignable to it.
    [cssVariableOrSelector: string]: string | IMobileSheetContentSx;
}

//
// The `sx` values produced for a MUI Joy `ModalDialog` on a desktop-sized screen. Kept as a concrete
// interface (rather than the broad Joy `SxProps` union) so the individual values can be asserted
// directly in unit tests. The shape is still assignable to a `ModalDialog`'s `sx` prop.
//
export interface IDesktopDialogSx {
    // Minimum dialog width; shrinks below the desktop minimum when the viewport is too narrow.
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
// How long the mobile sheet takes to slide up from the bottom edge. Joy's own default is 0.3s, which
// reads as slow when a sheet is opened repeatedly: the sheet should feel like it is already there,
// not like something the user waits for. Slightly longer than the desktop dialog's fade because the
// sheet travels the height of the panel rather than fading in place.
//
const SHEET_TRANSITION_DURATION = '0.2s';

//
// The easing of the sheet's slide. Decelerating: the sheet leaves the bottom edge quickly and eases
// into place, so it arrives settled rather than stopping dead.
//
const SHEET_TRANSITION_FUNCTION = 'cubic-bezier(0.32, 0.72, 0, 1)';

//
// The corner radius of the sheet's top edge, shared with Joy's `ModalClose` inset calculation.
//
const SHEET_CORNER_RADIUS = '20px';

//
// Builds the `sx` for the Joy `Drawer` that presents a dialog as a bottom sheet on a phone.
//
// A centred dialog is a desktop idiom: it wastes the width, strands its actions in the middle of the
// screen away from the thumb, and squeezes its content between two margins. A sheet anchored to the
// bottom edge uses the full width, puts the actions where the thumb already rests, and reads as
// native on a phone.
//
// A `Drawer` is used rather than a `Modal` styled to look like a sheet because Joy's `Drawer` slides
// its content in and out on its own, and stays mounted for the length of the closing slide. Joy's
// `Modal` has no transition at all and unmounts the instant it closes, so a sheet built on it can
// only ever appear and disappear abruptly.
//
export function mobileSheetDrawerSx(): IMobileSheetDrawerSx {
    return {
        '--Drawer-transitionDuration': SHEET_TRANSITION_DURATION,
        '--Drawer-transitionFunction': SHEET_TRANSITION_FUNCTION,
        '--Drawer-contentRadius': SHEET_CORNER_RADIUS,
        '& .MuiDrawer-content': {
            height: 'auto',
            maxHeight: 'calc(92vh - env(safe-area-inset-top))',
            borderRadius: `${SHEET_CORNER_RADIUS} ${SHEET_CORNER_RADIUS} 0px 0px`,
            padding: '12px 20px 0px 20px',
            paddingBottom: 'calc(20px + env(safe-area-inset-bottom))',
            '&::before': {
                content: '""',
                display: 'block',
                width: '36px',
                height: '4px',
                flexShrink: 0,
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
        },
    };
}

//
// Builds the `sx` for a MUI Joy `ModalDialog` on a desktop-sized screen: the dialog keeps its
// comfortable size (between `minWidth` and `maxWidth`), centred, with its actions in a right-aligned
// row. The dialog's entry animation is not set here; it comes from `.MuiModalDialog-root` in
// `styles.css`, so that every dialog picks it up whether or not it uses this function.
//
export function desktopDialogSx(minWidth: number, maxWidth: number): IDesktopDialogSx {
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
