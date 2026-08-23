import React, { useEffect, useState } from "react";
import Box from "@mui/joy/Box";
import Card from "@mui/joy/Card";
import Chip from "@mui/joy/Chip";
import Typography from "@mui/joy/Typography/Typography";
import { CloudUpload } from "@mui/icons-material";
import { log } from "utils";
import { usePlatform } from "../context/platform-context";
import type { IImportProgressMessage } from "api/src/lib/import-assets.types";

//
// Shows what an import is doing, on the Import page.
//
// It appears only once an import has actually reported something, so a user who has imported nothing
// is not shown an empty panel.
//
export function ImportProgress() {
    const platform = usePlatform();
    const [progress, setProgress] = useState<IImportProgressMessage | undefined>(undefined);

    useEffect(() => {
        const unsubscribe = platform.onTaskMessage((_taskId, message) => {
            if (message.type === "import-progress") {
                setProgress(message as unknown as IImportProgressMessage);
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
            variant="soft"
            sx={{ borderRadius: 'lg', p: 1.5, gap: 1, mb: 2 }}
            data-id="import-progress"
            >
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                <CloudUpload sx={{ color: 'text.secondary' }} />
                <Typography level="title-md" sx={{ flexGrow: 1 }}>Import</Typography>
            </Box>

            <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 1 }}>
                <Chip size="sm" color="success" data-id="import-imported-count">
                    {`Imported ${progress.imported}`}
                </Chip>
                <Chip size="sm" color="neutral" data-id="import-skipped-count">
                    {`Already there ${progress.skipped}`}
                </Chip>
                {progress.failed > 0
                    && <Chip size="sm" color="danger" data-id="import-failed-count">
                        {`Failed ${progress.failed}`}
                    </Chip>
                }
            </Box>

            {progress.currentItem
                && <Typography level="body-sm" sx={{ color: 'text.tertiary' }} data-id="import-current-item">
                    {progress.currentItem}
                </Typography>
            }
        </Card>
    );
}
