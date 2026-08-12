import React, { useEffect, useState } from "react";
import Box from "@mui/joy/Box";
import Card from "@mui/joy/Card";
import Chip from "@mui/joy/Chip";
import Typography from "@mui/joy/Typography/Typography";
import { CloudUpload } from "@mui/icons-material";
import { log } from "utils";
import { usePlatform } from "../context/platform-context";

//
// What the automatic import task reports as it works.
//
// Declared here rather than imported from node-api because this package is shared with the web and
// mobile builds and must not depend on the Node-side task code.
//
interface IAutoImportProgress {
    // How many items have been handed to the import.
    seen: number;

    // How many items were added to the database.
    imported: number;

    // How many were already there.
    skipped: number;

    // How many could not be imported.
    failed: number;

    // How many source files were deleted after being confirmed.
    deletedFromSource: number;

    // How many items of the existing library are still waiting their turn.
    backfillRemaining: number;

    // Whether the whole existing library has been walked.
    backfillComplete: boolean;

    // The item most recently handed to the import.
    currentItem: string | undefined;
}

//
// Shows what automatic import is doing, on the Import page.
//
// It appears only once automatic import has actually reported something, so a user who has never
// switched it on is not shown an empty panel about a feature they are not using.
//
export function AutoImportProgress() {
    const platform = usePlatform();
    const [progress, setProgress] = useState<IAutoImportProgress | undefined>(undefined);

    useEffect(() => {
        const unsubscribe = platform.onTaskMessage((_taskId, message) => {
            if (message.type === "auto-import-progress") {
                setProgress(message as unknown as IAutoImportProgress);
            }
        });

        return () => {
            unsubscribe();
        };
    }, [platform]);

    useEffect(() => {
        if (progress) {
            log.event("Automatic import progress shown");
        }
    }, [progress === undefined]);

    if (!progress) {
        return <></>;
    }

    return (
        <Card
            variant="soft"
            sx={{ borderRadius: 'lg', p: 1.5, gap: 1, mb: 2 }}
            data-id="auto-import-progress"
            >
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                <CloudUpload sx={{ color: 'text.secondary' }} />
                <Typography level="title-md" sx={{ flexGrow: 1 }}>Automatic import</Typography>
            </Box>

            <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 1 }}>
                <Chip size="sm" color="success" data-id="auto-import-imported-count">
                    {`Imported ${progress.imported}`}
                </Chip>
                <Chip size="sm" color="neutral" data-id="auto-import-skipped-count">
                    {`Already there ${progress.skipped}`}
                </Chip>
                {progress.failed > 0
                    && <Chip size="sm" color="danger" data-id="auto-import-failed-count">
                        {`Failed ${progress.failed}`}
                    </Chip>
                }
                {progress.deletedFromSource > 0
                    && <Chip size="sm" color="warning" data-id="auto-import-deleted-count">
                        {`Source files deleted ${progress.deletedFromSource}`}
                    </Chip>
                }
                {!progress.backfillComplete
                    && <Chip size="sm" color="primary" data-id="auto-import-backfill-remaining">
                        {`Catching up, ${progress.backfillRemaining} waiting`}
                    </Chip>
                }
            </Box>

            {progress.currentItem
                && <Typography level="body-sm" sx={{ color: 'text.tertiary' }} data-id="auto-import-current-item">
                    {progress.currentItem}
                </Typography>
            }
        </Card>
    );
}
