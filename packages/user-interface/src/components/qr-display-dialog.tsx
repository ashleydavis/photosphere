import React from "react";
import { QRCodeSVG } from "qrcode.react";
import Modal from "@mui/joy/Modal";
import ModalClose from "@mui/joy/ModalClose";
import ModalDialog from "@mui/joy/ModalDialog";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import Typography from "@mui/joy/Typography";
import { IDatabaseQrConfig, serializeDatabaseQrConfig } from "../lib/qr-code-format";

//
// Database connection configuration to encode in the QR code.
// The encryptionKey field is omitted because it exceeds the QR code data limit.
//
const DATABASE_QR_CONFIG: IDatabaseQrConfig = {
    name: "My Photos",
    path: "s3:my-bucket/photos",
    storage: {
        endpoint: "https://s3.amazonaws.com",
        region: "us-east-1",
        accessKeyId: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    },
    passPhrase: "maple drift anchor tunnel velvet gross frog orbit plank siren amber cloud rivet hinge blunt spark flint cedar prism anvil chalk ember gloom ivory latch",
};

const jsonPayload = "PSIE" + JSON.stringify(DATABASE_QR_CONFIG);
const delimitedPayload = "PSIE" + serializeDatabaseQrConfig(DATABASE_QR_CONFIG);
console.log(`[QR] JSON payload size:      ${jsonPayload.length} chars`);
console.log(`[QR] Delimited payload size: ${delimitedPayload.length} chars`);

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
                        value={delimitedPayload}
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
