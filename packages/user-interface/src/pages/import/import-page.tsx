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
import { FileUpload, CheckCircle, Cancel, HourglassEmpty, RemoveCircle, Close, FolderOpen, CleaningServices } from "@mui/icons-material";
import { useIsMobile } from "../../lib/use-is-mobile";
import type { IImportItem } from "../../context/import-context";
import { ImportProgress } from "../../components/import-progress";

//
// Shown when no database is loaded.
//
function NoDatabaseLoaded() {
    return (
        <Box className="flex items-center justify-center" sx={{ height: "100%" }}>
            <Typography variant="body1" sx={{ color: "var(--color-text-muted)" }}>
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
        return <HourglassEmpty sx={{ color: "var(--color-text-muted)", fontSize: "var(--icon-md)" }} />;
    }
    else if (status === 'success') {
        return <CheckCircle sx={{ color: "var(--color-success)", fontSize: "var(--icon-md)" }} />;
    }
    else if (status === 'failure') {
        return <Cancel sx={{ color: "var(--color-danger)", fontSize: "var(--icon-md)" }} />;
    }
    else {
        return <RemoveCircle sx={{ color: "var(--color-text-muted)", fontSize: "var(--icon-md)" }} />;
    }
}

//
// A single row in the import list showing one file's import status.
//
function ImportItemRow({ item }: { item: IImportItem }) {
    return (
        <Box
            className="flex flex-row items-center"
            sx={{
                gap: "var(--space-3)",
                padding: "var(--space-2) var(--space-4)",
                borderBottom: "1px solid var(--color-border)",
                background: "var(--color-import-item-bg)",
            }}
        >
            <Box
                sx={{
                    display: "flex",
                    width: "var(--icon-md)",
                    flexShrink: 0,
                }}
                >
                <ItemStatusIcon status={item.status} />
            </Box>

            <Box
                sx={{
                    width: "var(--button-height-sm)",
                    height: "var(--button-height-sm)",
                    flexShrink: 0,
                    borderRadius: "var(--radius-photo)",
                    overflow: "hidden",
                    background: "var(--color-raised)",
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

            <Typography
                data-id="import-item-path"
                variant="body2"
                sx={{
                    flexGrow: 1,
                    fontFamily: "var(--font-mono)",
                    fontSize: "var(--text-sm)",
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                }}
                >
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
        <Box
            className="flex flex-col"
            sx={{
                height: "100%",
                overflowY: "auto",
            }}
            >
            <Box
                className="flex flex-col"
                sx={{
                    flexGrow: 1,
                    minHeight: 0,
                    width: "100%",
                    maxWidth: "calc(var(--space-8) * 28)",
                    mx: "auto",
                    gap: "var(--space-4)",
                    padding: isMobile ? "var(--space-3)" : "var(--space-6)",
                }}
                >

                {/* What automatic import is doing, when it is doing anything. */}
                <ImportProgress />

                {/* Header bar: where the import is up to, with Cancel at the right while it runs. */}
                <Box
                    className="flex flex-row items-center"
                    sx={{
                        flexShrink: 0,
                        gap: "var(--space-3)",
                        minHeight: "var(--button-height-md)",
                        "& .MuiTypography-subtitle1": {
                            fontSize: "var(--text-lg)",
                            fontWeight: "var(--weight-bold)",
                        },
                    }}
                    >
                    {status === 'running' && (
                        <>
                            <CircularProgress size="var(--icon-lg)" />
                            <Typography variant="subtitle1" sx={{ flexGrow: 1 }}>Importing…</Typography>
                            <Button
                                data-id="import-cancel-button"
                                variant="outlined"
                                color="error"
                                size="small"
                                startIcon={<Close />}
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

                {/* Idle state */}
                {status === 'idle' && (
                    <Box
                        data-id="import-drop-zone"
                        className="flex flex-col items-center justify-center"
                        onDragOver={allowDragAndDrop ? handleDragOver : undefined}
                        onDragLeave={allowDragAndDrop ? handleDragLeave : undefined}
                        onDrop={allowDragAndDrop ? handleDrop : undefined}
                        sx={{
                            flexShrink: 0,
                            textAlign: "center",
                            gap: "var(--space-3)",
                            padding: isMobile ? "var(--space-6) var(--space-4)" : "var(--space-8) var(--space-6)",
                            background: isDragOver ? "color-mix(in srgb, var(--color-accent) 18%, var(--dropzone-fill))" : "var(--dropzone-fill)",
                            border: "var(--dropzone-border)",
                            borderStyle: isDragOver ? "solid" : undefined,
                            borderRadius: "var(--radius-lg)",
                            transition: "background var(--duration-fast) var(--ease-standard)",
                        }}
                    >
                        <Box
                            aria-hidden={true}
                            sx={{
                                display: "flex",
                                alignItems: "center",
                                justifyContent: "center",
                                width: "calc(var(--space-8) * 2)",
                                height: "calc(var(--space-8) * 2)",
                                borderRadius: "var(--radius-full)",
                                background: "var(--empty-icon-bg)",
                                color: "var(--color-empty-icon)",
                                fontSize: "var(--space-6)",
                                transform: isDragOver ? "translateY(calc(var(--space-1) * -1)) scale(1.08)" : "none",
                                transition: "transform var(--duration-normal) var(--ease-standard)",
                                "@media (prefers-reduced-motion: reduce)": {
                                    transition: "none",
                                },
                            }}
                            >
                            <FileUpload fontSize="inherit" />
                        </Box>
                        <Typography
                            variant={isMobile ? "h3" : "h4"}
                            sx={{
                                fontFamily: "var(--font-heading)",
                                fontSize: "var(--text-xl)",
                                fontWeight: "var(--weight-bold)",
                                lineHeight: "var(--leading-tight)",
                            }}
                            >
                            Import photos
                        </Typography>
                        <Typography
                            variant="body1"
                            sx={{
                                color: "var(--color-text-muted)",
                                maxWidth: "calc(var(--space-8) * 12)",
                            }}
                            >
                            {allowDragAndDrop
                                ? "Drop files or directories here, or use the buttons below."
                                : "Choose photos and videos from your device."}
                        </Typography>
                        {/* On a mobile the import buttons stack and run the full width of the
                            drop zone: a row of two large buttons is what clipped this page's actions
                            at the edges before, and a single obvious target beats two small ones. */}
                        <Box
                            sx={{
                                display: "flex",
                                flexDirection: isMobile ? "column" : "row",
                                flexWrap: "wrap",
                                gap: "var(--space-3)",
                                justifyContent: "center",
                                width: "100%",
                                marginTop: "var(--space-2)",
                            }}
                            >
                            <Button
                                data-id="import-files-button"
                                variant="contained"
                                size={isMobile ? "large" : "medium"}
                                startIcon={<FileUpload />}
                                onClick={handleImportFiles}
                                disabled={isPicking}
                            >
                                {platform.platformKind === "desktop" ? "Import files" : "Select photos"}
                            </Button>
                            {platform.platformKind === "desktop" && (
                                <Button
                                    data-id="import-directory-button"
                                    variant="outlined"
                                    size={isMobile ? "large" : "medium"}
                                    startIcon={<FolderOpen />}
                                    onClick={handleImportDirectories}
                                    disabled={isPicking}
                                >
                                    Import directory
                                </Button>
                            )}
                        </Box>
                    </Box>
                )}

                {/* The list shows while an import is happening or has just finished, and also when
                    nothing is happening but this database has imported something before. That last
                    case is the point of the record: opening a database should answer "what came in?"
                    without the user having to import something first. */}
                {(status === 'running' || status === 'completed' || status === 'cancelled' || importItems.length > 0) && (
                    <Box
                        component="section"
                        aria-label="Imported files"
                        className="flex flex-col overflow-hidden"
                        sx={{
                            flexGrow: 1,
                            minHeight: "calc(var(--space-8) * 6)",
                            background: "var(--color-panel)",
                            border: "1px solid var(--color-border)",
                            borderRadius: "var(--radius-md)",
                        }}
                        >

                        {/* Summary (only when done). Chips in a wrapping row, so the outcome reads at
                            a glance on a mobile instead of as four stacked lines of small text. */}
                        {(status === 'completed' || status === 'cancelled') && (
                            <Box
                                sx={{
                                    display: "flex",
                                    flexWrap: "wrap",
                                    gap: "var(--space-2)",
                                    padding: "var(--space-3) var(--space-4)",
                                    borderBottom: "1px solid var(--color-border)",
                                    flexShrink: 0,
                                    "& .MuiChip-icon": {
                                        fontSize: "var(--icon-sm)",
                                        color: "inherit",
                                        marginLeft: "var(--space-2)",
                                    },
                                }}
                            >
                                <Chip
                                    icon={<CheckCircle />}
                                    label={`${successCount} added`}
                                    sx={{
                                        color: "var(--color-success)",
                                        borderColor: "color-mix(in srgb, var(--color-success) 45%, transparent)",
                                        background: "color-mix(in srgb, var(--color-success) 14%, transparent)",
                                    }}
                                    />
                                <Chip
                                    icon={<RemoveCircle />}
                                    label={`${skippedCount} skipped`}
                                    sx={{
                                        color: "var(--color-text-muted)",
                                        borderColor: "var(--color-border)",
                                        background: "var(--color-raised)",
                                    }}
                                    />
                                <Chip
                                    icon={<Cancel />}
                                    label={`${failedCount} failed`}
                                    sx={{
                                        color: failedCount > 0 ? "var(--color-danger)" : "var(--color-text-muted)",
                                        borderColor: failedCount > 0 ? "var(--color-danger)" : "var(--color-border)",
                                        background: failedCount > 0 ? "color-mix(in srgb, var(--color-danger) 10%, transparent)" : "var(--color-raised)",
                                    }}
                                    />
                                {pendingCount > 0 && (
                                    <Chip
                                        icon={<HourglassEmpty />}
                                        label={`${pendingCount} pending`}
                                        sx={{
                                            color: "var(--color-warning)",
                                            borderColor: "color-mix(in srgb, var(--color-warning) 45%, transparent)",
                                            background: "color-mix(in srgb, var(--color-warning) 14%, transparent)",
                                        }}
                                        />
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
                                        color: 'var(--color-text-muted)',
                                        fontSize: 'var(--text-sm)',
                                        textAlign: 'center',
                                        padding: 'var(--space-3)',
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
                                    padding: "var(--space-3) var(--space-4)",
                                    borderTop: "1px solid var(--color-border)",
                                    flexShrink: 0,
                                }}
                            >
                                <Button
                                    data-id="import-clear-button"
                                    variant="outlined"
                                    size={isMobile ? "large" : "medium"}
                                    startIcon={<CleaningServices />}
                                    onClick={clearImport}
                                    fullWidth={isMobile}
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
