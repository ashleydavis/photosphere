//
// Styles applied to each individual action inside a mobile sheet's action row.
//
export interface IMobileDialogActionChildSx {
    // Fill the width of the stack.
    width: '100%';

    // Comfortable tap height, the style guide's large button height.
    minHeight: string;

    // Material's `DialogActions` spaces a row of actions with a left margin on every action after
    // the first, which would push all but the first action of the stack off to the right.
    marginLeft: string;
}

//
// Styles applied to a sheet's action row on a mobile. The actions become a full-width stack at the
// bottom of the sheet (the thumb end of the screen) instead of a cramped row.
//
export interface IMobileDialogActionsSx {
    // Stack the actions vertically. Reversed because every dialog writes its main action last,
    // and stacking should leave that main action on top.
    flexDirection: 'column-reverse';

    // Every action stretches across the sheet.
    alignItems: 'stretch';

    // Space between the stacked actions.
    gap: string;

    // The stack spans the sheet.
    width: '100%';

    // The line that sets the actions apart from the scrolling content above them.
    borderTop: string;

    // Room between that line and the first action.
    paddingTop: string;

    // Every action fills the width, giving a large, unmissable tap target.
    '& > *': IMobileDialogActionChildSx;

    // An icon button in the stack, such as a refresh button.
    '& > .MuiIconButton-root': IMobileDialogIconActionSx;
}

//
// Styles applied to an icon button in a mobile sheet's stack of actions. It keeps its square shape
// instead of stretching across the sheet like the text buttons.
//
export interface IMobileDialogIconActionSx {
    // As wide as the icon button is tall, not the width of the stack.
    width: 'auto';

    // As wide as the stack's tap height, so the button is square.
    minWidth: string;

    // Centred in the stack rather than stretched across it.
    alignSelf: 'center';
}

//
// Styles applied to the first action in a desktop dialog's action row.
//
export interface IDesktopDialogFirstActionSx {
    // Takes up the row's free space, so the first action (Cancel) sits alone at the left end and
    // every action after it groups at the right end, even when there are more than two.
    marginRight: 'auto';
}

//
// Styles applied to the only action in a desktop dialog's action row.
//
export interface IDesktopDialogOnlyActionSx {
    // Takes up the row's free space before it, so a lone action, which is the dialog's main
    // action, sits at the right end where the main action always sits.
    marginLeft: 'auto';
}

//
// Styles applied to each individual action in a desktop dialog's action row.
//
export interface IDesktopDialogActionChildSx {
    // Material's `DialogActions` spaces its actions with a left margin on every action after the
    // first, so the row's `gap` spaces the actions instead.
    marginLeft: string;
}

//
// Styles applied to a desktop dialog's action row. Every dialog writes Cancel first and its main
// action last, and the row spreads them to its two ends, as the style guide's dialogs do.
//
export interface IDesktopDialogActionsSx {
    // Lay the actions out left to right, in the order they are written.
    flexDirection: 'row';

    // Spread the actions to the ends of the row, as the style guide's token sets.
    justifyContent: string;

    // Space between the actions.
    gap: string;

    // Clears Material's own spacing between the actions. The selector is Material's own, so it
    // overrides Material's margin even when this is the `sx` of a `DialogActions` itself.
    '& > :not(style) ~ :not(style)': IDesktopDialogActionChildSx;

    // The first action, when it is not the only one.
    '& > :first-of-type:not(:last-of-type)': IDesktopDialogFirstActionSx;

    // The action, when it is the only one.
    '& > :first-of-type:last-of-type': IDesktopDialogOnlyActionSx;
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
}

//
// The grab handle drawn at the top of a mobile sheet: the small horizontal bar that signals the
// panel came up from the bottom edge.
//
export interface ISheetHandleSx {
    // Drawn with a pseudo-element, so no markup changes are needed across every dialog.
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

    // The handle colour the style guide sets for a sheet on a mobile.
    backgroundColor: string;

    // Centred, with space above it.
    margin: string;
}

//
// Places a dialog's close button (an `IconButton` placed directly in the dialog, beside its title)
// at the right end of the title row, so every dialog shows it in the same place.
//
export interface ICloseButtonSx {
    // Taken out of the flow, so the title keeps the full width of the dialog.
    position: 'absolute';

    // Distance from the top edge of the dialog.
    top: string;

    // Distance from the right edge of the dialog.
    right: string;

    // Sits above a sticky title, which would otherwise cover it on a mobile sheet.
    zIndex: number;
}

//
// Styles applied to a dialog title that follows a close button, so a long title wraps before it
// runs under the button.
//
export interface ITitleBesideCloseButtonSx {
    // Room at the right end of the title for the close button.
    paddingRight: string;
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

    // The theme draws a right edge on every drawer, which a sheet spanning the screen does not need.
    borderRight: string;

    // The title, content and actions bring their own padding.
    padding: string;

    // Bottom padding clears the system navigation bar / home indicator.
    paddingBottom: string;

    // The grab handle.
    '&::before': ISheetHandleSx;

    // The close button, at the right end of the title row.
    '& > .MuiIconButton-root': ICloseButtonSx;

    // A title that shares its row with the close button.
    '& > .MuiIconButton-root ~ .MuiDialogTitle-root': ITitleBesideCloseButtonSx;

    // The sticky title.
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

    // The close button at the right end of the title row.
    '& > .MuiIconButton-root': ICloseButtonSx;

    // A title that shares its row with the close button.
    '& > .MuiIconButton-root ~ .MuiDialogTitle-root': ITitleBesideCloseButtonSx;

    // The action row, spread to its two ends.
    '& .MuiDialogActions-root': IDesktopDialogActionsSx;
}

//
// The gap kept between a modal dialog and each edge of the viewport, so the dialog never touches or
// overflows the screen edges on small form factors. Used by both the width and height limits and
// the margin, which have to agree.
//
const VIEWPORT_GAP = 'var(--space-4)';

//
// Where the close button sits: level with the middle of the title's first line, and in from the
// dialog's right edge by the same amount. Shared by the dialog and the sheet so the button sits in
// the same place on both.
//
const CLOSE_BUTTON_INSET = 'var(--space-3)';

//
// The easing of the sheet's slide, passed to the `easing` of the Material `Drawer`'s slide
// transition. Material writes it into the paper's CSS `transition`, so a token works here.
//
export const SHEET_TRANSITION_EASING = 'var(--ease-standard)';

//
// Converts a CSS time such as "250ms" or "0.25s", as read from a duration token, to milliseconds,
// so ResponsiveDialog can hand the sheet's slide a token's duration through the Material `Drawer`'s
// `transitionDuration`, which takes a number. Returns undefined when the value is not a CSS time,
// so the caller falls back to Material's own duration.
//
export function cssTimeToMs(cssTime: string): number | undefined {
    const match = /^\s*([0-9]*\.?[0-9]+)(ms|s)\s*$/.exec(cssTime);
    if (!match) {
        return undefined;
    }
    const amount = Number(match[1]);
    if (match[2] === 's') {
        return amount * 1000;
    }
    return amount;
}

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
            maxHeight: 'calc(var(--dialog-sheet-max-height) - env(safe-area-inset-top))',
            borderRadius: 'var(--dialog-sheet-radius)',
            borderRight: 'none',
            padding: '0px',
            paddingBottom: 'env(safe-area-inset-bottom)',
            '&::before': {
                content: '""',
                display: 'block',
                width: 'calc(var(--space-8) + var(--space-1))',
                height: 'var(--space-1)',
                flexShrink: 0,
                borderRadius: 'var(--radius-full)',
                backgroundColor: 'var(--dialog-phone-handle-color)',
                margin: 'var(--space-2) auto 0px auto',
            },
            '& > .MuiIconButton-root': {
                position: 'absolute',
                top: `calc(var(--space-2) + var(--space-1) + ${CLOSE_BUTTON_INSET})`,
                right: CLOSE_BUTTON_INSET,
                zIndex: 3,
            },
            '& > .MuiIconButton-root ~ .MuiDialogTitle-root': {
                paddingRight: `calc(${CLOSE_BUTTON_INSET} + var(--button-height-md))`,
            },
            '& .MuiDialogTitle-root': {
                position: 'sticky',
                top: '0px',
                zIndex: 2,
                backgroundColor: 'inherit',
            },
            '& .MuiDialogActions-root': {
                flexDirection: 'column-reverse',
                alignItems: 'stretch',
                gap: 'var(--space-2)',
                width: '100%',
                borderTop: '1px solid var(--color-border)',
                paddingTop: 'var(--space-3)',
                '& > *': {
                    width: '100%',
                    minHeight: 'var(--button-height-lg)',
                    marginLeft: '0px',
                },
                '& > .MuiIconButton-root': {
                    width: 'auto',
                    minWidth: 'var(--button-height-lg)',
                    alignSelf: 'center',
                },
            },
        },
    };
}

//
// Builds the `sx` for a Material `Dialog`'s paper on a desktop-sized screen: the dialog keeps its
// comfortable size (between `minWidth` and `maxWidth`), centred, with Cancel and its main action at
// the two ends of the action row and its close button at the right end of the title row. The dialog
// fades in and out with Material's own transition.
//
export function desktopDialogSx(minWidth: number, maxWidth: number): IDesktopDialogSx {
    return {
        // Shrink below the desktop minimum when the viewport is too narrow to hold it.
        minWidth: `min(${minWidth}px, calc(100vw - 2 * ${VIEWPORT_GAP}))`,
        // Cap at the desktop maximum, but never exceed the viewport width.
        maxWidth: `min(${maxWidth}px, calc(100vw - 2 * ${VIEWPORT_GAP}))`,
        // Never taller than the visible viewport, accounting for mobile safe-area insets.
        maxHeight: `calc(100vh - env(safe-area-inset-top) - env(safe-area-inset-bottom) - 2 * ${VIEWPORT_GAP})`,
        // Scroll vertically when the content is tall; never scroll horizontally.
        overflowY: 'auto',
        overflowX: 'hidden',
        // Keep the viewport gap the width and height limits above allow for.
        margin: VIEWPORT_GAP,
        '& > .MuiIconButton-root': {
            position: 'absolute',
            top: CLOSE_BUTTON_INSET,
            right: CLOSE_BUTTON_INSET,
            zIndex: 3,
        },
        '& > .MuiIconButton-root ~ .MuiDialogTitle-root': {
            paddingRight: `calc(${CLOSE_BUTTON_INSET} + var(--button-height-md))`,
        },
        '& .MuiDialogActions-root': desktopDialogActionsSx(),
    };
}

//
// Builds the `sx` for a desktop dialog's action row: Cancel at the left end and the main action at
// the right end. desktopDialogSx applies it to every dialog shown through ResponsiveDialog, and a
// dialog built on Material's `Dialog` directly passes it to its own `DialogActions`, so the actions
// sit the same way in both.
//
export function desktopDialogActionsSx(): IDesktopDialogActionsSx {
    return {
        flexDirection: 'row',
        justifyContent: 'var(--dialog-actions-justify)',
        gap: 'var(--space-2)',
        '& > :not(style) ~ :not(style)': {
            marginLeft: '0px',
        },
        '& > :first-of-type:not(:last-of-type)': {
            marginRight: 'auto',
        },
        '& > :first-of-type:last-of-type': {
            marginLeft: 'auto',
        },
    };
}
