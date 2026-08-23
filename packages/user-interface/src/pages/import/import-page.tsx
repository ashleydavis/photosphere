import React, { useEffect, useRef, useState } from "react";
import { useAssetDatabase } from "../../context/asset-database-source";
import { useImport } from "../../context/import-context";
import { usePlatform, type IToolsStatus } from "../../context/platform-context";
import { log } from "utils";
import Box from "@mui/joy/Box";
import Button from "@mui/joy/Button";
import Chip from "@mui/joy/Chip";
import CircularProgress from "@mui/joy/CircularProgress";
import Typography from "@mui/joy/Typography";
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
            <Typography level="body-md" sx={{ color: "text.secondary" }}>
                Open a database to import photos.
            </Typography>
        </Box>
    );
}

//
// Panel shown when required tools are missing, with platform-specific install instructions.
//
function ToolsMissingPanel({ toolsStatus, onCheckAgain }: { toolsStatus: IToolsStatus; onCheckAgain: () => void }) {
    const missingList = toolsStatus.missingTools.join(' and ');
    const isMac = typeof process !== 'undefined' && process.platform === 'darwin';
    const isWin = typeof process !== 'undefined' && process.platform === 'win32';

    return (
        <Box sx={{ maxWidth: 600, mx: "auto", p: 3 }}>
            <Typography level="h4" sx={{ mb: 2, color: "warning.plainColor" }}>
                Required tools are not installed
            </Typography>
            <Typography level="body-md" sx={{ mb: 3 }}>
                {missingList} {toolsStatus.missingTools.length === 1 ? 'is' : 'are'} required to import photos and videos.
            </Typography>

            {isMac && (
                <Box sx={{ mb: 3 }}>
                    <Typography level="title-sm" sx={{ mb: 1 }}>macOS — Using Homebrew (recommended):</Typography>
                    <Box component="pre" sx={{ p: 2, borderRadius: "sm", bgcolor: "background.level1", fontSize: "sm", overflowX: "auto" }}>
                        brew install imagemagick ffmpeg
                    </Box>
                    <Typography level="title-sm" sx={{ mt: 2, mb: 1 }}>macOS — Manual download:</Typography>
                    <Typography level="body-sm">
                        ImageMagick: <a href="https://imagemagick.org/script/download.php#macosx" target="_blank" rel="noreferrer">imagemagick.org</a>
                        {' '}&nbsp;·&nbsp;{' '}
                        ffmpeg: <a href="https://evermeet.cx/ffmpeg/" target="_blank" rel="noreferrer">evermeet.cx/ffmpeg</a>
                    </Typography>
                </Box>
            )}

            {isWin && (
                <Box sx={{ mb: 3 }}>
                    <Typography level="title-sm" sx={{ mb: 1 }}>Windows — Using Chocolatey (recommended):</Typography>
                    <Box component="pre" sx={{ p: 2, borderRadius: "sm", bgcolor: "background.level1", fontSize: "sm", overflowX: "auto" }}>
                        choco install imagemagick ffmpeg
                    </Box>
                    <Typography level="title-sm" sx={{ mt: 2, mb: 1 }}>Windows — Using Scoop:</Typography>
                    <Box component="pre" sx={{ p: 2, borderRadius: "sm", bgcolor: "background.level1", fontSize: "sm", overflowX: "auto" }}>
                        scoop install imagemagick ffmpeg
                    </Box>
                    <Typography level="title-sm" sx={{ mt: 2, mb: 1 }}>Windows — Manual download:</Typography>
                    <Typography level="body-sm">
                        ImageMagick: <a href="https://imagemagick.org/script/download.php#windows" target="_blank" rel="noreferrer">imagemagick.org</a>
                        {' '}&nbsp;·&nbsp;{' '}
                        ffmpeg: <a href="https://www.gyan.dev/ffmpeg/builds/" target="_blank" rel="noreferrer">gyan.dev/ffmpeg</a>
                    </Typography>
                </Box>
            )}

            {!isMac && !isWin && (
                <Box sx={{ mb: 3 }}>
                    <Typography level="title-sm" sx={{ mb: 1 }}>Linux — Ubuntu/Debian:</Typography>
                    <Box component="pre" sx={{ p: 2, borderRadius: "sm", bgcolor: "background.level1", fontSize: "sm", overflowX: "auto" }}>
                        sudo apt update && sudo apt install imagemagick ffmpeg
                    </Box>
                    <Typography level="title-sm" sx={{ mt: 2, mb: 1 }}>Other distributions:</Typography>
                    <Typography level="body-sm">
                        Fedora/RHEL: <code>dnf install ImageMagick ffmpeg</code>
                        {' '}&nbsp;·&nbsp;{' '}
                        Arch: <code>pacman -S imagemagick ffmpeg</code>
                    </Typography>
                </Box>
            )}

            <Typography level="body-sm" sx={{ mb: 3 }}>
                For full instructions see:{' '}
                <a href="https://github.com/ashleydavis/photosphere/wiki/Required-Tools" target="_blank" rel="noreferrer">
                    Required Tools documentation
                </a>
            </Typography>

            <Typography level="body-sm" sx={{ mb: 2 }}>
                After installing, click the button below to re-check.
            </Typography>

            <Button variant="soft" color="neutral" onClick={onCheckAgain}>
                Check again
            </Button>
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
        return <CheckCircle fontSize="small" sx={{ color: "success.plainColor" }} />;
    }
    else if (status === 'failure') {
        return <Cancel fontSize="small" sx={{ color: "danger.plainColor" }} />;
    }
    else {
        return <RemoveCircle fontSize="small" sx={{ color: "neutral.plainColor" }} />;
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
                    borderRadius: "sm",
                    overflow: "hidden",
                    bgcolor: "background.level2",
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

            <Typography level="body-sm" sx={{ flexGrow: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {item.logicalPath}
            </Typography>

            {/* Which asked for it. A photo that arrived on its own is the one a user is most likely
                to be asking about, so it is marked rather than left to be guessed at. */}
            {item.source && (
                <Chip
                    size="sm"
                    variant="soft"
                    color={item.source === 'automatic' ? 'primary' : 'neutral'}
                    data-id={`import-source-${item.source}`}
                    sx={{ flexShrink: 0 }}
                >
                    {item.source === 'automatic' ? 'Automatic' : 'Manual'}
                </Chip>
            )}
        </Box>
    );
}

//
// The import page component. Manages tool checking, import triggering, and displays
// per-file progress during an import session.
//
export function ImportPage() {
    const { databasePath } = useAssetDatabase();
    const platform = usePlatform();
    const { status, importItems, recordTruncated, startImportDirectories, startImportFiles, isPicking, cancelImport, clearImport } = useImport();

    // Drives the phone layout: stacked full-width import buttons, chips for the summary.
    const isMobile = useIsMobile();

    // Tool check state: undefined = checking, null = check not run yet (but we auto-run on mount)
    const [toolsStatus, setToolsStatus] = useState<IToolsStatus | null>(null);
    const [isCheckingTools, setIsCheckingTools] = useState<boolean>(false);

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
    // Run tool check on mount (when a database is loaded), and again whenever the page returns to
    // idle. Status lives in the context above this page and survives navigation, so after one import
    // it is 'completed' or 'cancelled' rather than 'idle'. Depending on databasePath alone meant a
    // revisit ran the effect once, failed the guard, and left toolsStatus undefined, which switches
    // allowDragAndDrop off and makes every subsequent drop vanish without a word.
    //
    useEffect(() => {
        if (databasePath && status === 'idle') {
            runToolCheck();
        }
    // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [databasePath, status]);

    //
    // Runs the tool check and updates toolsStatus.
    //
    useEffect(() => {
        if (toolsStatus?.allAvailable) {
            log.event('Import page ready');
        }
    }, [toolsStatus]);

    async function runToolCheck() {
        setIsCheckingTools(true);
        const result = await platform.checkTools();
        setToolsStatus(result);
        setIsCheckingTools(false);
    }

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

    // Drag-and-drop import is only offered on platforms that support it (desktop) and once the media
    // tools are available. Mobile/web hide the drop zone and offer the native photo picker instead.
    const allowDragAndDrop = platform.supportsDragAndDropImport && (toolsStatus?.allAvailable ?? false);

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
                        <CircularProgress size="sm" />
                        <Typography level="title-md" sx={{ flexGrow: 1 }}>Importing…</Typography>
                        <Button
                            data-id="import-cancel-button"
                            variant="soft"
                            color="danger"
                            size="sm"
                            onClick={cancelImport}
                        >
                            Cancel
                        </Button>
                    </>
                )}

                {status === 'completed' && (
                    <Typography level="title-md" sx={{ flexGrow: 1 }}>Import complete</Typography>
                )}

                {status === 'cancelled' && (
                    <Typography level="title-md" sx={{ flexGrow: 1 }}>Import cancelled</Typography>
                )}

                {status === 'idle' && (
                    <Typography level="title-md">Import photos</Typography>
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
                            borderColor: isDragOver ? "primary.outlinedBorder" : "transparent",
                            borderRadius: "md",
                            transition: "border-color 0.15s",
                            bgcolor: isDragOver ? "primary.softBg" : undefined,
                        }}
                    >
                        {isCheckingTools && (
                            <CircularProgress size="md" />
                        )}

                        {!isCheckingTools && toolsStatus === null && (
                            <CircularProgress size="md" />
                        )}

                        {!isCheckingTools && toolsStatus !== null && toolsStatus.allAvailable && (
                            // On a phone the import buttons stack and run the full width of the
                            // screen: a row of two "lg" buttons is what clipped this page's actions
                            // at the edges before, and a single obvious target beats two small ones.
                            <Box sx={{ textAlign: "center", width: "100%", px: isMobile ? 3 : 0 }}>
                                <Box
                                    sx={{
                                        display: "inline-flex",
                                        alignItems: "center",
                                        justifyContent: "center",
                                        width: isMobile ? 96 : 80,
                                        height: isMobile ? 96 : 80,
                                        borderRadius: "50%",
                                        backgroundColor: "background.level2",
                                        mb: 2,
                                    }}
                                    >
                                    <FileUpload sx={{ fontSize: isMobile ? 48 : 40, color: "text.secondary" }} />
                                </Box>
                                <Typography level={isMobile ? "h3" : "h4"} sx={{ mb: 1 }}>Import photos</Typography>
                                <Typography level="body-md" sx={{ mb: 4, color: "text.secondary" }}>
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
                                        variant={isMobile ? "solid" : "soft"}
                                        color={isMobile ? "primary" : "neutral"}
                                        size="lg"
                                        startDecorator={<FileUpload />}
                                        onClick={handleImportFiles}
                                        disabled={isPicking}
                                        sx={{ minHeight: isMobile ? 52 : undefined, borderRadius: isMobile ? "md" : undefined }}
                                    >
                                        {platform.supportsDragAndDropImport ? "Import files" : "Select photos"}
                                    </Button>
                                    {platform.supportsDragAndDropImport && (
                                        <Button
                                            variant="soft"
                                            color="neutral"
                                            size="lg"
                                            startDecorator={<FileUpload />}
                                            onClick={handleImportDirectories}
                                            disabled={isPicking}
                                            sx={{ minHeight: isMobile ? 52 : undefined }}
                                        >
                                            Import directory
                                        </Button>
                                    )}
                                </Box>
                            </Box>
                        )}

                        {!isCheckingTools && toolsStatus !== null && !toolsStatus.allAvailable && (
                            <ToolsMissingPanel toolsStatus={toolsStatus} onCheckAgain={runToolCheck} />
                        )}
                    </Box>
                )}

                {/* The list shows while an import is happening or has just finished, and also when
                    nothing is happening but this database has imported something before. That last
                    case is the point of the record: opening a database should answer "what came in?"
                    without the user having to import something first. */}
                {(status === 'running' || status === 'completed' || status === 'cancelled' || importItems.length > 0) && (
                    <Box className="flex flex-col flex-grow overflow-hidden">

                        {/* Summary (only when done). Chips in a wrapping row, so the outcome reads at
                            a glance on a phone instead of as four stacked lines of small text. */}
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
                                <Chip variant="soft" color="success" size="lg">{`${successCount} added`}</Chip>
                                <Chip variant="soft" color="neutral" size="lg">{`${skippedCount} skipped`}</Chip>
                                <Chip
                                    variant="soft"
                                    color={failedCount > 0 ? "danger" : "neutral"}
                                    size="lg"
                                    >
                                    {`${failedCount} failed`}
                                </Chip>
                                {pendingCount > 0 && (
                                    <Chip variant="soft" color="warning" size="lg">{`${pendingCount} pending`}</Chip>
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
                                    level="body-xs"
                                    data-id="import-record-truncated"
                                    sx={{ color: 'text.tertiary', textAlign: 'center', py: 1.5 }}
                                >
                                    Imports older than these are not remembered.
                                </Typography>
                            )}
                        </Box>

                        {/* Clear button. Full width at the bottom of a phone screen, under the thumb. */}
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
                                    variant="soft"
                                    color="neutral"
                                    size={isMobile ? "lg" : "md"}
                                    onClick={clearImport}
                                    sx={{ width: isMobile ? "100%" : undefined, minHeight: isMobile ? 48 : undefined }}
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
