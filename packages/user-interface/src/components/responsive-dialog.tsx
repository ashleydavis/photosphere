import React, { ReactNode, KeyboardEvent } from 'react';
import Dialog from '@mui/material/Dialog';
import Drawer from '@mui/material/Drawer';
import { useIsMobile } from '../lib/use-is-mobile';
import { cssTimeToMs, desktopDialogSx, mobileSheetDrawerSx, SHEET_TRANSITION_EASING } from '../lib/modal-styles';

declare module '@mui/material/Dialog' {
    //
    // Lets a dialog's paper take the `data-id` the smoke tests find the dialog by. Material types
    // its slot props strictly, so an attribute it does not list has to be added here.
    //
    interface DialogPaperSlotPropsOverrides {
        //
        // Identifies the dialog to the smoke tests.
        //
        'data-id'?: string;
    }
}

declare module '@mui/material/Drawer' {
    //
    // Lets a drawer's paper take the `data-id` the smoke tests find the sheet by. Material types its
    // slot props strictly, so an attribute it does not list has to be added here.
    //
    interface DrawerPaperSlotPropsOverrides {
        //
        // Identifies the sheet to the smoke tests.
        //
        'data-id'?: string;
    }
}

export interface IProps {
    //
    // Set to true to display the dialog.
    //
    open: boolean;

    //
    // Event raised to dismiss the dialog. Pass undefined to prevent the dialog being dismissed by
    // clicking away from it or pressing escape, for example while an operation is in progress.
    //
    onClose: (() => void) | undefined;

    //
    // The dialog's preferred width (in pixels) on a desktop-sized screen. Ignored on a mobile, where
    // the dialog is a sheet that spans the screen.
    //
    minWidth: number;

    //
    // The dialog's maximum width (in pixels) on a desktop-sized screen. Ignored on a mobile, where
    // the dialog is a sheet that spans the screen.
    //
    maxWidth: number;

    //
    // Handles a key press anywhere in the dialog, typically to confirm on enter.
    //
    onKeyDown?: (event: KeyboardEvent) => void;

    //
    // Identifies the dialog to the smoke tests.
    //
    dataId?: string;

    //
    // The dialog's content: normally a DialogTitle, a DialogContent and a DialogActions.
    //
    children: ReactNode;
}

//
// Presents a dialog in the form that suits the screen it is on.
//
// On a desktop-sized screen it is a centred modal dialog. On a mobile it is a sheet that slides up
// from the bottom edge, which uses the full width, puts the actions under the thumb, and reads as
// native.
//
// The two forms are different Material components (a Dialog and a Drawer) rather than one component
// restyled by a media query, because the Drawer brings the slide from the bottom edge where the
// Dialog fades in place. The cost is that crossing the breakpoint remounts the dialog, which in
// practice only happens when a desktop window is resized across it.
//
// The `data-id` goes on the paper, the dialog's visible surface. The key handler goes on the root,
// because Material focuses the dialog's container rather than its paper when the dialog opens, and a
// key press there reaches the root but not the paper.
//
export function ResponsiveDialog({ open, onClose, minWidth, maxWidth, onKeyDown, dataId, children }: IProps) {

    const isMobile = useIsMobile();

    if (isMobile) {
        //
        // The sheet slides for as long as the style guide's normal duration token says. Material's
        // Drawer takes its duration as a number, so the token is read from the page here.
        //
        const transitionDuration = cssTimeToMs(getComputedStyle(document.documentElement).getPropertyValue('--duration-normal'));
        return (
            <Drawer
                anchor="bottom"
                open={open}
                onClose={onClose}
                onKeyDown={onKeyDown}
                transitionDuration={transitionDuration}
                sx={mobileSheetDrawerSx()}
                slotProps={{
                    paper: {
                        'data-id': dataId,
                    },
                    transition: {
                        easing: SHEET_TRANSITION_EASING,
                    },
                }}
                >
                {children}
            </Drawer>
        );
    }

    return (
        <Dialog
            open={open}
            onClose={onClose}
            onKeyDown={onKeyDown}
            maxWidth={false}
            fullWidth={false}
            slotProps={{
                paper: {
                    'data-id': dataId,
                    sx: desktopDialogSx(minWidth, maxWidth),
                },
            }}
            >
            {children}
        </Dialog>
    );
}
