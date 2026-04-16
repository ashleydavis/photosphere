import React from "react";
import { QRCodeSVG } from "qrcode.react";
import Modal from "@mui/joy/Modal";
import ModalClose from "@mui/joy/ModalClose";
import ModalDialog from "@mui/joy/ModalDialog";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import Typography from "@mui/joy/Typography";

//
// Database connection configuration to encode in the QR code.
// The encryptionKey field is omitted because it exceeds the QR code data limit (~3000 bytes).
//
const DATABASE_QR_CONFIG = {
    name: "My Photos",
    path: "s3:my-bucket/photos",
    storage: {
        endpoint: "https://s3.amazonaws.com",
        region: "us-east-1",
        accessKeyId: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    },
};

export interface IQrDisplayDialogProps {
    //
    // Set to true to display the dialog.
    //
    open: boolean;

    //
    // Event raised when the dialog is closed.
    //
    onClose: () => void;
}

//
// Modal dialog that shows a QR code encoding the database access configuration.
//
export function QrDisplayDialog({ open, onClose }: IQrDisplayDialogProps) {
    return (
        <Modal open={open} onClose={onClose}>
            <ModalDialog>
                <ModalClose />
                <DialogTitle>Database Access QR Code</DialogTitle>
                <DialogContent>
                    <QRCodeSVG
                        value={"PSIE" + JSON.stringify(DATABASE_QR_CONFIG)}
                        size={600}
                        level="L"
                        marginSize={8}
                        bgColor="#ffffff"
                        fgColor="#000000"
                        style={{ maxWidth: "100%", height: "auto" }}
                        />
                    <Typography level="body-sm" sx={{ mt: 1 }}>
                        Scan to access database
                    </Typography>
                </DialogContent>
            </ModalDialog>
        </Modal>
    );
}
