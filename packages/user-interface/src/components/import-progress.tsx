import React, { useEffect, useState } from "react";
import Box from "@mui/material/Box";
import Card from "@mui/material/Card";
import Chip from "@mui/material/Chip";
import Typography from "@mui/material/Typography";
import { CloudUpload } from "@mui/icons-material";
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
        <Card
            elevation={0}
            sx={{
                display: 'flex',
                flexDirection: 'column',
                bgcolor: 'action.hover',
                borderRadius: 3,
                p: 1.5,
                gap: 1,
                mb: 2,
            }}
            data-id="import-progress"
            >
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                <CloudUpload sx={{ color: 'text.secondary' }} />
                <Typography variant="subtitle1" sx={{ flexGrow: 1 }}>Import</Typography>
            </Box>

            <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 1 }}>
                <Chip
                    size="small"
                    color="success"
                    data-id="import-imported-count"
                    label={`Imported ${progress.imported}`}
                    />
                <Chip
                    size="small"
                    color="default"
                    data-id="import-skipped-count"
                    label={`Already there ${progress.skipped}`}
                    />
                {progress.failed > 0
                    && <Chip
                        size="small"
                        color="error"
                        data-id="import-failed-count"
                        label={`Failed ${progress.failed}`}
                        />
                }
            </Box>

            {progress.currentItem
                && <Typography variant="body2" sx={{ color: 'text.secondary' }} data-id="import-current-item">
                    {progress.currentItem}
                </Typography>
            }
        </Card>
    );
}
