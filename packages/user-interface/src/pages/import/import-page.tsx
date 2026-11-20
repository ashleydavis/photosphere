import React, { useEffect, useRef, useState } from "react";
import { useAssetDatabase } from "../../context/asset-database-source";
import { useImport } from "../../context/import-context";
import { usePlatform } from "../../context/platform-context";
import { log } from "utils";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import Chip from "@mui/material/Chip";
import CircularProgress from "@mui/material/CircularProgress";
import Typography from "@mui/material/Typography";
import { FileUpload, CheckCircle, Cancel, HourglassEmpty, RemoveCircle } from "@mui/icons-material";
import { useIsMobile } from "../../lib/use-is-mobile";
import type { IImportItem } from "../../context/import-context";
import { ImportProgress } from "../../components/import-progress";

//
// Shown when no database is loaded.
//
function NoDatabaseLoaded() {
    return (
        <Box className="flex items-center justify-center" sx={{ height: "calc(100vh - 60px)" }}>
            <Typography variant="body1" sx={{ color: "text.secondary" }}>
                Open a database to import photos.
            </Typography>
        </Box>
    );
}

//
// Status icon for a single import item row.
//
function ItemStatusIcon({ status }: { status: IImportItem['status'] }) {
    if (status === 'pending') {
        return <HourglassEmpty fontSize="small" sx={{ color: "text.secondary" }} />;
    }
    else if (status === 'success') {
        return <CheckCircle fontSize="small" sx={{ color: "success.main" }} />;
    }
    else if (status === 'failure') {
        return <Cancel fontSize="small" sx={{ color: "error.main" }} />;
    }
    else {
        return <RemoveCircle fontSize="small" sx={{ color: "text.secondary" }} />;
    }
}

//
// A single row in the import list showing one file's import status.
//
function ImportItemRow({ item }: { item: IImportItem }) {
    return (
        <Box
            className="flex flex-row items-center py-1 px-2 gap-2"
            sx={{ borderBottom: "1px solid", borderColor: "divider" }}
        >
            <Box sx={{ width: 20, flexShrink: 0 }}>
                <ItemStatusIcon status={item.status} />
            </Box>

            <Box
                sx={{
                    width: 32,
                    height: 32,
                    flexShrink: 0,
                    borderRadius: 1.5,
                    overflow: "hidden",
                    bgcolor: "action.selected",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                }}
            >
                {item.micro
                    ? <img
                        src={`data:image/jpeg;base64,${item.micro}`}
                        alt=""
                        style={{ width: "100%", height: "100%", objectFit: "cover" }}
                      />
                    : null
                }
            </Box>

            <Typography data-id="import-item-path" variant="body2" sx={{ flexGrow: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {item.logicalPath}
            </Typography>
        </Box>
    );
}

//
// The import page component. Manages import triggering, and displays
// per-file progress during an import session.
//
export function ImportPage() {
    const { databasePath } = useAssetDatabase();
    const platform = usePlatform();
    const { status, importItems, recordTruncated, startImportDirectories, startImportFiles, isPicking, cancelImport, clearImport } = useImport();

    // Drives the mobile layout: stacked full-width import buttons, chips for the summary.
    const isMobile = useIsMobile();

    // True while files are being dragged over the drop zone.
    const [isDragOver, setIsDragOver] = useState<boolean>(false);

    // Ref for the scrollable list container so we can auto-scroll to bottom.
    const listRef = useRef<HTMLDivElement>(null);

    //
    // Auto-scroll the list to the bottom whenever a new item is added.
    //
    useEffect(() => {
        if (listRef.current) {
            listRef.current.scrollTop = listRef.current.scrollHeight;
        }
    }, [importItems.length]);

    //
    // Tells the log the page is ready for an import when a database is loaded and the page is idle:
    // on mount, and again whenever the page returns to idle. Status lives in the context above this
    // page and survives navigation, so after one import it is 'completed' or 'cancelled' rather than
    // 'idle'.
    //
    useEffect(() => {
        if (databasePath && status === 'idle') {
            log.event('Import page ready');
        }
    }, [databasePath, status]);

    //
    // Opens a directory picker and starts an import.
    //
    async function handleImportDirectories() {
        await startImportDirectories();
    }

    //
    // Opens a file picker and starts an import.
    //
    async function handleImportFiles() {
        await startImportFiles();
    }

    //
    // Allows the drag event to proceed so the drop target activates.
    //
    function handleDragOver(event: React.DragEvent<HTMLDivElement>) {
        event.preventDefault();
        setIsDragOver(true);
    }

    //
    // Clears the drag-over highlight when the cursor leaves the drop zone.
    //
    function handleDragLeave(event: React.DragEvent<HTMLDivElement>) {
        event.preventDefault();
        setIsDragOver(false);
    }

    //
    // Extracts file system paths from the dropped items and starts an import.
    //
    async function handleDrop(event: React.DragEvent<HTMLDivElement>) {
        event.preventDefault();
        setIsDragOver(false);

        const injectedPaths = event.dataTransfer.getData('application/x-photosphere-paths');
        const droppedPaths: string[] = injectedPaths
            ? JSON.parse(injectedPaths) as string[]
            : Array.from(event.dataTransfer.files)
                .map(file => platform.getPathForFile(file))
                .filter(filePath => filePath !== undefined && filePath.length > 0) as string[];

        if (droppedPaths.length > 0) {
            await startImportDirectories(droppedPaths);
        }
    }

    if (!databasePath) {
        return <NoDatabaseLoaded />;
    }

    // Drag-and-drop import is only offered on platforms that support it (desktop). Mobile/web hide the
    // drop zone and offer the native photo picker instead.
    const allowDragAndDrop = platform.platformKind === "desktop";

    const successCount = importItems.filter(item => item.status === 'success').length;
    const skippedCount = importItems.filter(item => item.status === 'skipped').length;
    const failedCount = importItems.filter(item => item.status === 'failure').length;
    const pendingCount = importItems.filter(item => item.status === 'pending').length;

    return (
        <Box className="flex flex-col" sx={{ height: "calc(100vh - 60px)" }}>

            {/* What automatic import is doing, when it is doing anything. */}
            <Box sx={{ px: 2, pt: 2, flexShrink: 0 }}>
                <ImportProgress />
            </Box>

            {/* Header bar */}
            <Box
                className="flex flex-row items-center px-4 py-3 gap-3"
                sx={{ borderBottom: "1px solid", borderColor: "divider", flexShrink: 0 }}
            >
                {status === 'running' && (
                    <>
                        <CircularProgress size={24} />
                        <Typography variant="subtitle1" sx={{ flexGrow: 1 }}>Importing…</Typography>
                        <Button
                            data-id="import-cancel-button"
                            variant="outlined"
                            color="error"
                            size="small"
                            onClick={cancelImport}
                        >
                            Cancel
                        </Button>
                    </>
                )}

                {status === 'completed' && (
                    <Typography variant="subtitle1" sx={{ flexGrow: 1 }}>Import complete</Typography>
                )}

                {status === 'cancelled' && (
                    <Typography variant="subtitle1" sx={{ flexGrow: 1 }}>Import cancelled</Typography>
                )}

                {status === 'idle' && (
                    <Typography variant="subtitle1">Import photos</Typography>
                )}
            </Box>

            {/* Body */}
            <Box className="flex flex-col flex-grow overflow-hidden">

                {/* Idle state */}
                {status === 'idle' && (
                    <Box
                        data-id="import-drop-zone"
                        className="flex flex-col items-center justify-center flex-grow"
                        onDragOver={allowDragAndDrop ? handleDragOver : undefined}
                        onDragLeave={allowDragAndDrop ? handleDragLeave : undefined}
                        onDrop={allowDragAndDrop ? handleDrop : undefined}
                        sx={{
                            border: isDragOver ? "2px dashed" : "2px dashed transparent",
                            borderColor: isDragOver ? "primary.light" : "transparent",
                            borderRadius: 2,
                            transition: "border-color 0.15s",
                            bgcolor: isDragOver ? "rgba(var(--mui-palette-primary-mainChannel) / 0.08)" : undefined,
                        }}
                    >
                        {/* On a mobile the import buttons stack and run the full width of the
                            screen: a row of two large buttons is what clipped this page's actions
                            at the edges before, and a single obvious target beats two small ones. */}
                        <Box sx={{ textAlign: "center", width: "100%", px: isMobile ? 3 : 0 }}>
                            <Box
                                sx={{
                                    display: "inline-flex",
                                    alignItems: "center",
                                    justifyContent: "center",
                                    width: isMobile ? 96 : 80,
                                    height: isMobile ? 96 : 80,
                                    borderRadius: "50%",
                                    backgroundColor: "action.selected",
                                    mb: 2,
                                }}
                                >
                                <FileUpload sx={{ fontSize: isMobile ? 48 : 40, color: "text.secondary" }} />
                            </Box>
                            <Typography variant={isMobile ? "h3" : "h4"} sx={{ mb: 1 }}>Import photos</Typography>
                            <Typography variant="body1" sx={{ mb: 4, color: "text.secondary" }}>
                                {allowDragAndDrop
                                    ? "Drop files or directories here, or use the buttons below."
                                    : "Choose photos and videos from your device."}
                            </Typography>
                            <Box
                                sx={{
                                    display: "flex",
                                    flexDirection: isMobile ? "column" : "row",
                                    gap: 1.5,
                                    justifyContent: "center",
                                    width: "100%",
                                    maxWidth: isMobile ? 420 : undefined,
                                    mx: "auto",
                                }}
                                >
                                <Button
                                    data-id="import-files-button"
                                    variant={isMobile ? "contained" : "outlined"}
                                    color={isMobile ? "primary" : "inherit"}
                                    size="large"
                                    startIcon={<FileUpload />}
                                    onClick={handleImportFiles}
                                    disabled={isPicking}
                                    sx={{
                                        minHeight: isMobile ? 52 : undefined,
                                        borderRadius: isMobile ? 2 : undefined,
                                    }}
                                >
                                    {platform.platformKind === "desktop" ? "Import files" : "Select photos"}
                                </Button>
                                {platform.platformKind === "desktop" && (
                                    <Button
                                        data-id="import-directory-button"
                                        variant="outlined"
                                        color="inherit"
                                        size="large"
                                        startIcon={<FileUpload />}
                                        onClick={handleImportDirectories}
                                        disabled={isPicking}
                                        sx={{ minHeight: isMobile ? 52 : undefined }}
                                    >
                                        Import directory
                                    </Button>
                                )}
                            </Box>
                        </Box>
                    </Box>
                )}

                {/* The list shows while an import is happening or has just finished, and also when
                    nothing is happening but this database has imported something before. That last
                    case is the point of the record: opening a database should answer "what came in?"
                    without the user having to import something first. */}
                {(status === 'running' || status === 'completed' || status === 'cancelled' || importItems.length > 0) && (
                    <Box className="flex flex-col flex-grow overflow-hidden">

                        {/* Summary (only when done). Chips in a wrapping row, so the outcome reads at
                            a glance on a mobile instead of as four stacked lines of small text. */}
                        {(status === 'completed' || status === 'cancelled') && (
                            <Box
                                sx={{
                                    display: "flex",
                                    flexWrap: "wrap",
                                    gap: 1,
                                    px: 2,
                                    py: 1.5,
                                    borderBottom: "1px solid",
                                    borderColor: "divider",
                                    flexShrink: 0,
                                }}
                            >
                                <Chip color="success" size="medium" label={`${successCount} added`} />
                                <Chip color="default" size="medium" label={`${skippedCount} skipped`} />
                                <Chip
                                    color={failedCount > 0 ? "error" : "default"}
                                    size="medium"
                                    label={`${failedCount} failed`}
                                    />
                                {pendingCount > 0 && (
                                    <Chip color="warning" size="medium" label={`${pendingCount} pending`} />
                                )}
                            </Box>
                        )}

                        {/* Scrollable item list */}
                        <Box
                            ref={listRef}
                            className="flex-grow overflow-y-auto"
                        >
                            {importItems.map((item, index) => (
                                <ImportItemRow key={`${item.assetId}-${index}`} item={item} />
                            ))}

                            {/* Said out loud when the record is full, because a list that silently
                                stops is read as the whole history. */}
                            {recordTruncated && (
                                <Typography
                                    variant="caption"
                                    data-id="import-record-truncated"
                                    sx={{
                                        display: 'block',
                                        color: 'text.secondary',
                                        textAlign: 'center',
                                        py: 1.5,
                                    }}
                                >
                                    Imports older than these are not remembered.
                                </Typography>
                            )}
                        </Box>

                        {/* Clear button. Full width at the bottom of a mobile screen, under the thumb. */}
                        {(status === 'completed' || status === 'cancelled') && (
                            <Box
                                sx={{
                                    display: "flex",
                                    justifyContent: isMobile ? "stretch" : "flex-end",
                                    px: 2,
                                    py: 1.5,
                                    borderTop: "1px solid",
                                    borderColor: "divider",
                                    flexShrink: 0,
                                }}
                            >
                                <Button
                                    data-id="import-clear-button"
                                    variant="outlined"
                                    color="inherit"
                                    size={isMobile ? "large" : "medium"}
                                    onClick={clearImport}
                                    sx={{
                                        width: isMobile ? "100%" : undefined,
                                        minHeight: isMobile ? 48 : undefined,
                                    }}
                                    >
                                    Clear
                                </Button>
                            </Box>
                        )}
                    </Box>
                )}
            </Box>
        </Box>
    );
}
