//
// Styles applied to each individual action inside a mobile sheet's action row.
//
export interface IMobileDialogActionChildSx {
    // Fill the width of the stack.
    width: '100%';

    // Comfortable tap height. Material's minimum touch target is 48px.
    minHeight: string;

    // Material's `DialogActions` spaces a row of actions with a left margin on every action after
    // the first, which would push all but the first action of the stack off to the right.
    marginLeft: string;
}

//
// Styles applied to a sheet's action row on a mobile. The actions become a full-width stack at the
// bottom of the sheet (the thumb end of the screen) instead of a cramped right-aligned row.
//
export interface IMobileDialogActionsSx {
    // Stack the actions vertically. Reversed because the desktop's right-aligned row puts the
    // primary action last, and stacking should leave that primary action on top.
    flexDirection: 'column-reverse';

    // Space between the stacked actions.
    gap: string;

    // The stack spans the sheet.
    width: '100%';

    // Every action fills the width, giving a large, unmissable tap target.
    '& > *': IMobileDialogActionChildSx;
}

//
// Styles applied to each individual action in a desktop dialog's action row.
//
export interface IDesktopDialogActionChildSx {
    // Material's `DialogActions` spaces its actions with a left margin on every action after the
    // first. In a reversed row that margin lands on the outer side of the action, so the row's `gap`
    // spaces the actions instead.
    marginLeft: string;
}

//
// Styles applied to a desktop dialog's action row. The row runs right to left, so the first action
// in the markup sits at the right-hand end, the order every dialog's actions are written in.
//
export interface IDesktopDialogActionsSx {
    // Lay the actions out from the right-hand end.
    flexDirection: 'row-reverse';

    // In a reversed row the start is the right-hand edge, so this keeps the actions right-aligned.
    justifyContent: 'flex-start';

    // Space between the actions.
    gap: string;

    // Clears Material's own spacing between the actions. The selector is Material's own, so it
    // overrides Material's margin even when this is the `sx` of a `DialogActions` itself.
    '& > :not(style) ~ :not(style)': IDesktopDialogActionChildSx;
}

//
// Styles applied to a sheet's title on a mobile. The title stays put while the body scrolls, so it
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
// Places a dialog's close button (an `IconButton` placed directly in the dialog, beside its title)
// in the dialog's top-right corner, out of the title's way, so every dialog shows it in the same place.
//
export interface ICloseButtonSx {
    // Taken out of the flow, so the title keeps the full width of the dialog.
    position: 'absolute';

    // Distance from the top edge of the dialog.
    top: string;

    // Distance from the right edge of the dialog.
    right: string;
}

//
// Styles applied to the Material `Drawer`'s paper: the sheet itself, as opposed to the backdrop
// behind it. These values make it hug its content and give it the sheet's rounded top, padding,
// handle, close button, title and actions.
//
export interface IMobileSheetContentSx {
    // A dialog should be only as tall as its content, never a fixed fraction of the screen.
    height: 'auto';

    // Tall enough to be useful, short enough to leave the screen behind it partly visible, and
    // never running under the status bar.
    maxHeight: string;

    // Rounded at the top only, because the bottom edge runs off the screen.
    borderRadius: string;

    // Room above the grab handle. The title, content and actions bring their own side padding.
    padding: string;

    // Bottom padding clears the system navigation bar / home indicator.
    paddingBottom: string;

    // The grab handle.
    '&::before': ISheetHandleSx;

    // The close button, inset to suit the sheet's rounded corner.
    '& > .MuiIconButton-root': ICloseButtonSx;

    // The sticky, larger title.
    '& .MuiDialogTitle-root': IMobileDialogTitleSx;

    // Full-width stacked actions.
    '& .MuiDialogActions-root': IMobileDialogActionsSx;
}

//
// The `sx` values produced for the Material `Drawer` that presents a dialog as a bottom sheet on a
// mobile. Kept as a concrete interface (rather than the broad Material `SxProps` union) so the
// individual values can be asserted directly in unit tests.
//
export interface IMobileSheetDrawerSx {
    // The sheet panel itself.
    '& .MuiDrawer-paper': IMobileSheetContentSx;

    // Material's `sx` prop accepts nested selectors only through an index signature. Without this
    // the key above is not assignable to it.
    [selector: string]: IMobileSheetContentSx;
}

//
// The `sx` values produced for a Material `Dialog`'s paper on a desktop-sized screen. Kept as a
// concrete interface (rather than the broad Material `SxProps` union) so the individual values can be
// asserted directly in unit tests. It is still assignable to the paper's `sx` prop.
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

    // Space kept between the dialog and the edges of the viewport. Material's default margin is
    // wider than the gap the width and height limits above leave for it.
    margin: string;

    // The close button in the dialog's top-right corner.
    '& > .MuiIconButton-root': ICloseButtonSx;

    // The right-to-left action row.
    '& .MuiDialogActions-root': IDesktopDialogActionsSx;
}

//
// Gap (in pixels) kept between a modal dialog and each edge of the viewport so
// the dialog never touches or overflows the screen edges on small form factors.
//
const VIEWPORT_GAP_PX = 16;

//
// How long (in milliseconds) the mobile sheet takes to slide up from the bottom edge, passed to the
// Material `Drawer`'s `transitionDuration`. Material's own default is 225ms in and 195ms out, which
// reads as slow when a sheet is opened repeatedly: the sheet should feel like it is already there,
// not like something the user waits for. Slightly longer than the desktop dialog's fade because the
// sheet travels the height of the panel rather than fading in place.
//
export const SHEET_TRANSITION_DURATION_MS = 200;

//
// The easing of the sheet's slide. Decelerating: the sheet leaves the bottom edge quickly and eases
// into place, so it arrives settled rather than stopping dead. Passed to the `easing` of the Material
// `Drawer`'s slide transition.
//
export const SHEET_TRANSITION_EASING = 'cubic-bezier(0.32, 0.72, 0, 1)';

//
// The corner radius of the sheet's top edge, shared with the inset of the sheet's close button so the
// button sits evenly in the rounded corner.
//
const SHEET_CORNER_RADIUS = '20px';

//
// Builds the `sx` for the Material `Drawer` that presents a dialog as a bottom sheet on a mobile.
//
// A centred dialog is a desktop idiom: it wastes the width, strands its actions in the middle of the
// screen away from the thumb, and squeezes its content between two margins. A sheet anchored to the
// bottom edge uses the full width, puts the actions where the thumb already rests, and reads as
// native on a mobile.
//
// A `Drawer` is used rather than a `Dialog` styled to look like a sheet because Material's `Drawer`
// slides its paper in from the bottom edge and back out, where a `Dialog` fades in place.
//
export function mobileSheetDrawerSx(): IMobileSheetDrawerSx {
    return {
        '& .MuiDrawer-paper': {
            height: 'auto',
            maxHeight: 'calc(92vh - env(safe-area-inset-top))',
            borderRadius: `${SHEET_CORNER_RADIUS} ${SHEET_CORNER_RADIUS} 0px 0px`,
            padding: '12px 0px 0px 0px',
            paddingBottom: 'calc(20px + env(safe-area-inset-bottom))',
            '&::before': {
                content: '""',
                display: 'block',
                width: '36px',
                height: '4px',
                flexShrink: 0,
                borderRadius: '2px',
                backgroundColor: 'var(--mui-palette-divider)',
                margin: '0px auto 12px auto',
            },
            '& > .MuiIconButton-root': {
                position: 'absolute',
                top: `calc(${SHEET_CORNER_RADIUS} / 2)`,
                right: `calc(${SHEET_CORNER_RADIUS} / 2)`,
            },
            '& .MuiDialogTitle-root': {
                position: 'sticky',
                top: '0px',
                zIndex: 2,
                backgroundColor: 'inherit',
                fontSize: '1.5rem',
                paddingBottom: '12px',
            },
            '& .MuiDialogActions-root': {
                flexDirection: 'column-reverse',
                gap: '8px',
                width: '100%',
                '& > *': {
                    width: '100%',
                    minHeight: '48px',
                    marginLeft: '0px',
                },
            },
        },
    };
}

//
// Builds the `sx` for a Material `Dialog`'s paper on a desktop-sized screen: the dialog keeps its
// comfortable size (between `minWidth` and `maxWidth`), centred, with its actions in a right-aligned
// row and its close button in the top-right corner. The dialog fades in and out with Material's own
// transition.
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
        // Keep the viewport gap the width and height limits above allow for.
        margin: `${VIEWPORT_GAP_PX}px`,
        // The close button sits in the top-right corner, clear of the title.
        '& > .MuiIconButton-root': {
            position: 'absolute',
            top: '8px',
            right: '8px',
        },
        '& .MuiDialogActions-root': desktopDialogActionsSx(),
    };
}

//
// Builds the `sx` for a desktop dialog's action row, laid out right to left. desktopDialogSx applies
// it to every dialog shown through ResponsiveDialog, and a dialog built on Material's `Dialog`
// directly passes it to its own `DialogActions`, so the actions sit in the same order in both.
//
export function desktopDialogActionsSx(): IDesktopDialogActionsSx {
    return {
        flexDirection: 'row-reverse',
        justifyContent: 'flex-start',
        gap: '8px',
        '& > :not(style) ~ :not(style)': {
            marginLeft: '0px',
        },
    };
}
