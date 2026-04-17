import { useCallback, useEffect, useRef, useState } from "react";
import { BrowserQRCodeReader, IScannerControls } from "@zxing/browser";
import { NotFoundException, ChecksumException, FormatException } from "@zxing/library";
import { log } from "utils";
import { IDatabaseQrConfig } from "../lib/qr-code-format";
import Box from "@mui/joy/Box";
import Modal from "@mui/joy/Modal";
import ModalClose from "@mui/joy/ModalClose";
import ModalDialog from "@mui/joy/ModalDialog";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import Typography from "@mui/joy/Typography";


//
// Crosshair colour when no QR code is detected in the frame.
//
const CROSSHAIR_IDLE_COLOR = "rgba(255, 255, 255, 0.85)";

//
// Crosshair colour when a valid Photosphere QR code is detected.
//
const CROSSHAIR_DETECTED_COLOR = "rgba(0, 220, 100, 0.95)";

//
// Crosshair colour when a QR code is detected but is not a Photosphere code.
//
const CROSSHAIR_WRONG_CODE_COLOR = "rgba(255, 160, 0, 0.95)";

//
// How long (ms) the crosshairs stay green after the last QR detection before reverting.
//
const QR_DETECTED_LINGER_MS = 500;

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
    const [scannedData, setScannedData] = useState<IDatabaseQrConfig | null>(null);
    const [scanError, setScanError] = useState<string | null>(null);
    const [wrongCode, setWrongCode] = useState<boolean>(false);

    //
    // Direct ref to the crosshair overlay div. The crosshair colour is driven via a
    // CSS custom property on this element so that ZXing detections do not trigger React
    // re-renders, which would interfere with the continuous camera scan.
    //
    const overlayRef = useRef<HTMLDivElement | null>(null);
    const qrDetectedTimerRef = useRef<NodeJS.Timeout | null>(null);

    //
    // Callback ref — triggers a re-render (and thus the effect) once the video element mounts.
    //
    const videoCallbackRef = useCallback((element: HTMLVideoElement | null) => {
        setVideoElement(element);
    }, []);

    //
    // Sets the crosshair colour directly on the DOM without going through React state.
    //
    function setCrosshairColor(color: string): void {
        if (overlayRef.current) {
            overlayRef.current.style.setProperty("--crosshair-color", color);
        }
    }

    useEffect(() => {
        if (!open) {
            if (controlsRef.current) {
                controlsRef.current.stop();
                controlsRef.current = null;
            }
            if (qrDetectedTimerRef.current) {
                clearTimeout(qrDetectedTimerRef.current);
                qrDetectedTimerRef.current = null;
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
                        setCrosshairColor(CROSSHAIR_WRONG_CODE_COLOR);
                        if (qrDetectedTimerRef.current) {
                            clearTimeout(qrDetectedTimerRef.current);
                        }
                        qrDetectedTimerRef.current = setTimeout(() => {
                            setCrosshairColor(CROSSHAIR_IDLE_COLOR);
                        }, QR_DETECTED_LINGER_MS);
                        setWrongCode(true);
                        return;
                    }

                    //
                    // Attempt to deserialize — the format code inside the payload may still
                    // be unrecognised even though the PSIE prefix matched.
                    //
                    let config;
                    try {
                        config = JSON.parse(text.slice(4)) as IDatabaseQrConfig;
                    }
                    catch (parseErr) {
                        log.warn(`[QR] Failed to parse Photosphere QR payload: ${parseErr}`);
                        setCrosshairColor(CROSSHAIR_WRONG_CODE_COLOR);
                        if (qrDetectedTimerRef.current) {
                            clearTimeout(qrDetectedTimerRef.current);
                        }
                        qrDetectedTimerRef.current = setTimeout(() => {
                            setCrosshairColor(CROSSHAIR_IDLE_COLOR);
                        }, QR_DETECTED_LINGER_MS);
                        setWrongCode(true);
                        return;
                    }

                    //
                    // Valid Photosphere QR code — turn the crosshairs green.
                    //
                    setCrosshairColor(CROSSHAIR_DETECTED_COLOR);
                    setWrongCode(false);
                    controls.stop();
                    setScannedData(config);
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
            if (qrDetectedTimerRef.current) {
                clearTimeout(qrDetectedTimerRef.current);
                qrDetectedTimerRef.current = null;
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
                                    {JSON.stringify(scannedData, null, 2)}
                                </Typography>
                            </>
                            : <>
                                <Box sx={{ position: "relative", width: "100%" }}>
                                    <video
                                        ref={videoCallbackRef}
                                        autoPlay
                                        playsInline
                                        muted
                                        style={{ width: "100%", maxHeight: "60vh", display: "block" }}
                                        />

                                    {/*
                                      * Crosshairs + corner brackets overlay.
                                      * Colour is controlled via --crosshair-color set directly on this
                                      * div to avoid React re-renders during continuous camera scanning.
                                      */}
                                    <div
                                        ref={overlayRef}
                                        style={{
                                            position: "absolute",
                                            inset: 0,
                                            pointerEvents: "none",
                                            // @ts-ignore — CSS custom properties are valid but not in React.CSSProperties
                                            "--crosshair-color": CROSSHAIR_IDLE_COLOR,
                                        }}
                                        >
                                        {/* Horizontal crosshair line */}
                                        <Box sx={{
                                            position: "absolute",
                                            top: "50%",
                                            left: "15%",
                                            right: "15%",
                                            height: "1px",
                                            background: "var(--crosshair-color)",
                                            transform: "translateY(-50%)",
                                            transition: "background 0.2s ease",
                                        }} />

                                        {/* Vertical crosshair line */}
                                        <Box sx={{
                                            position: "absolute",
                                            left: "50%",
                                            top: "15%",
                                            bottom: "15%",
                                            width: "1px",
                                            background: "var(--crosshair-color)",
                                            transform: "translateX(-50%)",
                                            transition: "background 0.2s ease",
                                        }} />

                                        {/* Corner bracket — top left */}
                                        <Box sx={{
                                            position: "absolute",
                                            top: "15%",
                                            left: "15%",
                                            width: 24,
                                            height: 24,
                                            borderTop: "2px solid var(--crosshair-color)",
                                            borderLeft: "2px solid var(--crosshair-color)",
                                            transition: "border-color 0.2s ease",
                                        }} />

                                        {/* Corner bracket — top right */}
                                        <Box sx={{
                                            position: "absolute",
                                            top: "15%",
                                            right: "15%",
                                            width: 24,
                                            height: 24,
                                            borderTop: "2px solid var(--crosshair-color)",
                                            borderRight: "2px solid var(--crosshair-color)",
                                            transition: "border-color 0.2s ease",
                                        }} />

                                        {/* Corner bracket — bottom left */}
                                        <Box sx={{
                                            position: "absolute",
                                            bottom: "15%",
                                            left: "15%",
                                            width: 24,
                                            height: 24,
                                            borderBottom: "2px solid var(--crosshair-color)",
                                            borderLeft: "2px solid var(--crosshair-color)",
                                            transition: "border-color 0.2s ease",
                                        }} />

                                        {/* Corner bracket — bottom right */}
                                        <Box sx={{
                                            position: "absolute",
                                            bottom: "15%",
                                            right: "15%",
                                            width: 24,
                                            height: 24,
                                            borderBottom: "2px solid var(--crosshair-color)",
                                            borderRight: "2px solid var(--crosshair-color)",
                                            transition: "border-color 0.2s ease",
                                        }} />

                                    </div>
                                </Box>

                                {wrongCode
                                    ? <Typography level="body-sm" color="warning" sx={{ mt: 1 }}>
                                        Not a Photosphere QR code. Please scan a Photosphere QR code.
                                    </Typography>
                                    : <Typography level="body-sm" sx={{ mt: 1 }}>
                                        Point the camera at a Photosphere QR code
                                    </Typography>
                                }

                                <Box component="ul" sx={{ mt: 0.5, mb: 0, pl: 2.5 }}>
                                    <Typography component="li" level="body-xs" textColor="text.tertiary">
                                        Fill as much of the camera view as possible with the QR code
                                    </Typography>
                                    <Typography component="li" level="body-xs" textColor="text.tertiary">
                                        Make sure the QR code is well lit and free from glare
                                    </Typography>
                                    <Typography component="li" level="body-xs" textColor="text.tertiary">
                                        Try moving the QR code closer or further away to help the camera focus
                                    </Typography>
                                    <Typography component="li" level="body-xs" textColor="text.tertiary">
                                        Hold the QR code steady for a second or two
                                    </Typography>
                                </Box>
                            </>
                    }
                </DialogContent>
            </ModalDialog>
        </Modal>
    );
}
