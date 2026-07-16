import React, { ReactNode, KeyboardEvent } from 'react';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import Drawer from '@mui/joy/Drawer';
import { useIsMobile } from '../lib/use-is-mobile';
import { desktopDialogSx, mobileSheetDrawerSx } from '../lib/modal-styles';

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
    // The dialog's preferred width (in pixels) on a desktop-sized screen. Ignored on a phone, where
    // the dialog is a sheet that spans the screen.
    //
    minWidth: number;

    //
    // The dialog's maximum width (in pixels) on a desktop-sized screen. Ignored on a phone, where
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
// On a desktop-sized screen it is a centred modal dialog. On a phone it is a sheet that slides up
// from the bottom edge, which uses the full width, puts the actions under the thumb, and reads as
// native.
//
// The two forms are different Joy components (a Modal and a Drawer) rather than one component
// restyled by a media query, because Joy's Drawer brings the slide animation and Joy's Modal has no
// transition of its own. The cost is that crossing the breakpoint remounts the dialog, which in
// practice only happens when a desktop window is resized across it.
//
export function ResponsiveDialog({ open, onClose, minWidth, maxWidth, onKeyDown, dataId, children }: IProps) {

    const isMobile = useIsMobile();

    if (isMobile) {
        return (
            <Drawer
                anchor="bottom"
                open={open}
                onClose={onClose}
                onKeyDown={onKeyDown}
                data-id={dataId}
                sx={mobileSheetDrawerSx()}
                >
                {children}
            </Drawer>
        );
    }

    return (
        <Modal
            open={open}
            onClose={onClose}
            >
            <ModalDialog
                onKeyDown={onKeyDown}
                data-id={dataId}
                sx={desktopDialogSx(minWidth, maxWidth)}
                >
                {children}
            </ModalDialog>
        </Modal>
    );
}
