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
    encryptionKey: "-----BEGIN PRIVATE KEY-----\n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\n2vU72H0EbsPmzN/CHsOxqeoli/+Kcw==\n-----END PRIVATE KEY-----\n",
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
