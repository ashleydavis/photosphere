import React, { useEffect, useState } from "react";
import Box from "@mui/material/Box";
import Chip from "@mui/material/Chip";
import Typography from "@mui/material/Typography";
import { CloudUpload, CheckCircle, RemoveCircle, Cancel } from "@mui/icons-material";
import { log } from "utils";
import { usePlatform } from "../context/platform-context";
import type { IImportProgressEvent } from "api/src/lib/import-assets.types";

//
// Shows what an import is doing, on the Import page.
//
// It appears only once an import has actually reported something, so a user who has imported nothing
// is not shown an empty panel.
//
export function ImportProgress() {
    const platform = usePlatform();
    const [progress, setProgress] = useState<IImportProgressEvent | undefined>(undefined);

    useEffect(() => {
        const unsubscribe = platform.onTaskMessage((_taskId, message) => {
            if (message.type === "import-progress") {
                setProgress(message as unknown as IImportProgressEvent);
            }
        });

        return () => {
            unsubscribe();
        };
    }, [platform]);

    useEffect(() => {
        if (progress) {
            log.event("Import progress shown");
        }
    }, [progress === undefined]);

    if (!progress) {
        return <></>;
    }

    return (
        <Box
            component="section"
            aria-label="Import"
            sx={{
                display: 'flex',
                flexDirection: 'column',
                flexShrink: 0,
                gap: 'var(--space-3)',
                padding: 'var(--space-4)',
                background: 'var(--color-panel)',
                border: '1px solid var(--color-border)',
                borderRadius: 'var(--radius-md)',
                boxShadow: 'var(--shadow-raised)',
            }}
            data-id="import-progress"
            >
            <Box
                sx={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 'var(--space-3)',
                }}
                >
                <Box
                    aria-hidden={true}
                    sx={{
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        flex: 'none',
                        width: 'var(--button-height-md)',
                        height: 'var(--button-height-md)',
                        borderRadius: 'var(--radius-md)',
                        background: 'var(--color-chip-bg)',
                        color: 'var(--color-chip-text)',
                        fontSize: 'var(--icon-lg)',
                    }}
                    >
                    <CloudUpload fontSize="inherit" />
                </Box>
                <Typography
                    variant="subtitle1"
                    sx={{
                        flexGrow: 1,
                        fontWeight: 'var(--weight-bold)',
                    }}
                    >
                    Import
                </Typography>
            </Box>

            <Box
                sx={{
                    display: 'flex',
                    flexWrap: 'wrap',
                    gap: 'var(--space-2)',
                    '& .MuiChip-icon': {
                        fontSize: 'var(--icon-sm)',
                        color: 'inherit',
                        marginLeft: 'var(--space-2)',
                    },
                }}
                >
                <Chip
                    size="small"
                    icon={<CheckCircle />}
                    data-id="import-imported-count"
                    label={`Imported ${progress.imported}`}
                    sx={{
                        color: 'var(--color-success)',
                        borderColor: 'color-mix(in srgb, var(--color-success) 45%, transparent)',
                        background: 'color-mix(in srgb, var(--color-success) 14%, transparent)',
                    }}
                    />
                <Chip
                    size="small"
                    icon={<RemoveCircle />}
                    data-id="import-skipped-count"
                    label={`Already there ${progress.skipped}`}
                    sx={{
                        color: 'var(--color-text-muted)',
                        borderColor: 'var(--color-border)',
                        background: 'var(--color-raised)',
                    }}
                    />
                {progress.failed > 0
                    && <Chip
                        size="small"
                        icon={<Cancel />}
                        data-id="import-failed-count"
                        label={`Failed ${progress.failed}`}
                        sx={{
                            color: 'var(--color-danger)',
                            borderColor: 'var(--color-danger)',
                            background: 'color-mix(in srgb, var(--color-danger) 10%, transparent)',
                        }}
                        />
                }
            </Box>

            {progress.currentItem
                && <Typography
                    variant="body2"
                    sx={{
                        color: 'var(--color-text-muted)',
                        fontFamily: 'var(--font-mono)',
                        fontSize: 'var(--text-sm)',
                        overflowWrap: 'anywhere',
                    }}
                    data-id="import-current-item"
                    >
                    {progress.currentItem}
                </Typography>
            }
        </Box>
    );
}
