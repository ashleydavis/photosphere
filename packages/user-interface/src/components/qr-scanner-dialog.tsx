import { useCallback, useEffect, useRef, useState } from "react";
import { BrowserQRCodeReader, IScannerControls } from "@zxing/browser";
import { NotFoundException, ChecksumException, FormatException } from "@zxing/library";
import { log } from "utils";
import Modal from "@mui/joy/Modal";
import ModalClose from "@mui/joy/ModalClose";
import ModalDialog from "@mui/joy/ModalDialog";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import Typography from "@mui/joy/Typography";

//
// Props for the QR scanner dialog.
//
export interface IQrScannerDialogProps {
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
// Modal dialog that uses the camera to continuously scan for a QR code.
//
export function QrScannerDialog({ open, onClose }: IQrScannerDialogProps) {
    const controlsRef = useRef<IScannerControls | null>(null);
    const [videoElement, setVideoElement] = useState<HTMLVideoElement | null>(null);
    const [scannedData, setScannedData] = useState<string | null>(null);
    const [scanError, setScanError] = useState<string | null>(null);
    const [wrongCode, setWrongCode] = useState<boolean>(false);

    //
    // Callback ref — triggers a re-render (and thus the effect) once the video element mounts.
    //
    const videoCallbackRef = useCallback((element: HTMLVideoElement | null) => {
        setVideoElement(element);
    }, []);

    useEffect(() => {
        if (!open) {
            if (controlsRef.current) {
                controlsRef.current.stop();
                controlsRef.current = null;
            }
            setScannedData(null);
            setScanError(null);
            setWrongCode(false);
            return;
        }

        if (!videoElement) {
            return;
        }

        const codeReader = new BrowserQRCodeReader();

        codeReader.decodeFromConstraints(
            { video: true },
            videoElement,
            (result, err, controls) => {
                if (result) {
                    const text = result.getText();
                    log.info(`[QR] Decoded: ${text}`);
                    if (!text.startsWith("PSIE")) {
                        log.warn("[QR] Not a Photosphere QR code, continuing scan");
                        setWrongCode(true);
                        return;
                    }
                    setWrongCode(false);
                    controls.stop();
                    setScannedData(text.slice(4));
                }
                if (err && !(err instanceof NotFoundException) && !(err instanceof ChecksumException) && !(err instanceof FormatException)) {
                    log.error(`[QR] Scan error: ${err}`);
                }
            }
        )
        .then(controls => {
            controlsRef.current = controls;
        })
        .catch(err => {
            log.error(`[QR] Failed to start scanner: ${err}`);
            setScanError(`Failed to access camera: ${err}`);
        });

        return () => {
            if (controlsRef.current) {
                controlsRef.current.stop();
                controlsRef.current = null;
            }
        };
    }, [open, videoElement]);

    return (
        <Modal open={open} onClose={onClose}>
            <ModalDialog sx={{ width: "80vw", maxWidth: 800 }}>
                <ModalClose />
                <DialogTitle>Scan QR Code</DialogTitle>
                <DialogContent>
                    {scanError !== null
                        ? <Typography level="body-sm" color="danger">{scanError}</Typography>
                        : scannedData !== null
                            ? <>
                                <Typography level="body-sm" sx={{ mb: 1 }}>Decoded:</Typography>
                                <Typography
                                    level="body-xs"
                                    sx={{ fontFamily: "monospace", whiteSpace: "pre-wrap", wordBreak: "break-all", background: "var(--joy-palette-background-level1)", p: 1, borderRadius: "sm" }}
                                    >
                                    {scannedData}
                                </Typography>
                            </>
                            : <>
                                <video
                                    ref={videoCallbackRef}
                                    autoPlay
                                    playsInline
                                    muted
                                    style={{ width: "100%", maxHeight: "60vh" }}
                                    />
                                {wrongCode
                                    ? <Typography level="body-sm" color="warning" sx={{ mt: 0.5 }}>
                                        Not a Photosphere QR code. Please scan a Photosphere QR code.
                                    </Typography>
                                    : <Typography level="body-sm" sx={{ mt: 0.5 }}>
                                        Hold QR code in front of the camera
                                    </Typography>
                                }
                            </>
                    }
                </DialogContent>
            </ModalDialog>
        </Modal>
    );
}
