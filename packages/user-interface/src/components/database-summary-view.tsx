import React, { useEffect, useRef, useState } from "react";
import { log } from "utils";
import { TaskQueue, TaskStatus } from "task-queue";
import Box from "@mui/joy/Box";
import Card from "@mui/joy/Card";
import Typography from "@mui/joy/Typography";
import CircularProgress from "@mui/joy/CircularProgress";
import { Storage, Photo, Folder, Save, CloudSync } from "@mui/icons-material";
import { useAssetDatabase } from "../context/asset-database-source";
import { useUuidGenerator } from "../context/uuid-generator-context";
import { formatBytes, getStorageType } from "../lib/database-summary-format";
import type { IDatabaseSummary } from "node-api";
import type { IGetDatabaseSummaryData } from "node-api";
import Button from "@mui/joy/Button";
import { ConsolidateDatabaseDialog } from "./consolidate-database-dialog";

//
// Props for a single headline statistic.
//
interface IStatTileProps {
    // The statistic's name.
    label: string;

    // The statistic's value, already formatted for display.
    value: string;

    // Icon identifying the statistic at a glance.
    icon: React.ReactNode;
}

//
// A single headline statistic, shown as a tile with the number given real size. On a phone this is
// what the page is for: the numbers should be readable at arm's length, not buried in a label/value
// table built for a wide screen.
//
function StatTile({ label, value, icon }: IStatTileProps) {
    return (
        <Card
            variant="soft"
            sx={{ borderRadius: 'lg', p: 2, gap: 0.5, minWidth: 0 }}
            >
            <Box sx={{ color: 'text.tertiary', display: 'flex' }}>
                {icon}
            </Box>
            <Typography level="h2" sx={{ fontSize: '1.6rem', lineHeight: 1.1 }}>
                {value}
            </Typography>
            <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                {label}
            </Typography>
        </Card>
    );
}

//
// Props for a single labelled row of detail.
//
interface ISummaryRowProps {
    // Identifies the row to the smoke-test driver, rendered as the row's `data-id`.
    dataId: string;

    // Label for the row.
    label: string;

    // Value to display.
    value: string;
}

//
// A labelled row of detail. The label sits above the value rather than beside it, because a
// side-by-side row leaves a phone with a 48px-wide column for a value that is often a long path or
// a 64-character hash.
//
function SummaryRow({ dataId, label, value }: ISummaryRowProps) {
    return (
        <Box data-id={dataId} sx={{ py: 1.25, borderBottom: '1px solid', borderColor: 'divider' }}>
            <Typography level="body-xs" sx={{ color: 'text.tertiary', textTransform: 'uppercase', letterSpacing: '0.06em' }}>
                {label}
            </Typography>
            <Typography level="body-sm" sx={{ fontFamily: 'monospace', wordBreak: 'break-all', mt: 0.25 }}>
                {value}
            </Typography>
        </Box>
    );
}

//
// Props for a titled group of detail rows.
//
interface ISummarySectionProps {
    // The group's heading.
    title: string;

    // The rows in the group.
    children: React.ReactNode | React.ReactNode[];
}

//
// A titled group of detail rows, presented as a card.
//
function SummarySection({ title, children }: ISummarySectionProps) {
    return (
        <Card variant="outlined" sx={{ borderRadius: 'lg', p: 2, mt: 2, gap: 0 }}>
            <Typography level="title-md" sx={{ mb: 0.5 }}>{title}</Typography>
            {children}
        </Card>
    );
}

//
// The summary of the currently open database: its headline numbers, where it lives, and its hashes.
//
// Rendered both by the Database Summary page and by the dialog the navbar's photo count opens, so
// the two cannot drift apart. It carries no page chrome of its own, so whichever renders it supplies
// the heading and the surrounding box.
//
export function DatabaseSummaryView() {
    const { databasePath } = useAssetDatabase();
    const uuidGenerator = useUuidGenerator();

    //
    // The loaded summary data, or undefined while loading.
    //
    const [summary, setSummary] = useState<IDatabaseSummary | undefined>(undefined);

    //
    // Error message if the summary task failed.
    //
    const [error, setError] = useState<string | undefined>(undefined);

    //
    // Whether the summary is currently being fetched.
    //
    const [isLoading, setIsLoading] = useState(false);

    // Whether the connect-to-remote dialog is open.
    const [consolidateOpen, setConsolidateOpen] = useState(false);

    //
    // The task queue used to run the get-database-summary task.
    // Held in a ref so it persists across renders and can be shut down on cleanup.
    //
    const queue = useRef<TaskQueue | undefined>(undefined);

    useEffect(() => {
        if (!databasePath) {
            setSummary(undefined);
            setError(undefined);
            return;
        }

        setSummary(undefined);
        setError(undefined);
        setIsLoading(true);

        //todo: Queue mgmt should go in a context probably.

        //
        // A source of this view's own, not one built from the database path. The page and the
        // dialog both render this component, so a path-derived name is shared between them, and
        // cancelling it on one unmount takes the other's tasks with it. Cancelling a source and
        // queueing under it race across the bridge to the mobile worker pool: leaving the summary
        // page and opening the dialog sends a cancel and an add for the same name at almost the
        // same moment, and under load the cancel lands second and drops the task that had already
        // been queued, so the dialog waits on a summary that will never arrive.
        //
        queue.current = new TaskQueue(uuidGenerator, `database-summary-${uuidGenerator.generate()}`);

        const taskData: IGetDatabaseSummaryData = { databasePath };
        const taskId = queue.current.addTask("get-database-summary", taskData);

        queue.current.awaitTask(taskId).then(result => {
            if (!result) {
                return;
            }
            if (result.status === TaskStatus.Succeeded) {
                const loadedSummary = result.outputs as IDatabaseSummary;
                setSummary(loadedSummary);
                // Observable success line so a smoke test can confirm the get-database-summary
                // handler ran and returned data.
                log.info(`Database summary loaded: ${loadedSummary.totalImports} imports, ${loadedSummary.totalFiles} files`);
            }
            else {
                const summaryError = result.errorMessage || "Failed to load database summary";
                setError(summaryError);
                log.error(`Database summary failed: ${summaryError}`);
            }
            setIsLoading(false);
        });

        return () => {
            queue.current?.shutdown();
            queue.current = undefined;
        };
    }, [databasePath, uuidGenerator]);

    return (
        <>
            {!databasePath
                && <Typography level="body-md" sx={{ color: 'text.tertiary' }}>
                    No database is currently open.
                </Typography>
            }

            {databasePath
                && <>
                    {isLoading
                        && <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, py: 3 }}>
                            <CircularProgress size="sm" />
                            <Typography level="body-md" sx={{ color: 'text.tertiary' }}>
                                Loading summary...
                            </Typography>
                        </Box>
                    }

                    {error
                        && <Card variant="soft" color="danger" sx={{ borderRadius: 'lg', p: 2 }}>
                            <Typography level="body-md" color="danger">{error}</Typography>
                        </Card>
                    }

                    {/*
                        Two fixed columns rather than a wrapping flex row. Wrapping stretched
                        whatever landed on the last row to the full width, so the fourth tile read
                        as a banner across the modal instead of one of four. Two columns put the
                        four stats in a square at every width this is rendered at, and no tile is
                        ever left alone on a row of its own.
                    */}
                    {summary
                        && <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 1.5 }}>
                            <StatTile
                                label="Photos and videos"
                                value={summary.totalImports.toLocaleString()}
                                icon={<Photo />}
                                />
                            <StatTile
                                label="Files"
                                value={summary.totalFiles.toLocaleString()}
                                icon={<Folder />}
                                />
                            <StatTile
                                label="Total size"
                                value={formatBytes(summary.totalSize)}
                                icon={<Save />}
                                />
                            <StatTile
                                label="Database version"
                                value={summary.databaseVersion.toString()}
                                icon={<Storage />}
                                />
                        </Box>
                    }

                    <SummarySection title="Location">
                        <SummaryRow dataId="database-path" label="Path" value={databasePath} />
                        <SummaryRow dataId="database-storage-type" label="Storage type" value={getStorageType(databasePath)} />
                        {summary
                            && <SummaryRow dataId="database-mode" label="Mode" value={summary.mode} />
                        }
                    </SummarySection>

                    <SummarySection title="Remote copy">
                        <Typography level="body-sm" sx={{ color: 'text.tertiary', mb: 1 }}>
                            Keeps a copy of this database on a remote. If the remote already holds a
                            different database, the two are joined and nothing it already has is
                            uploaded again.
                        </Typography>
                        <Button
                            size="sm"
                            variant="outlined"
                            startDecorator={<CloudSync />}
                            data-id="summary-consolidate-database-button"
                            onClick={() => { log.info('Consolidate into remote dialog opened'); setConsolidateOpen(true); }}
                            >
                            Consolidate into remote
                        </Button>
                    </SummarySection>

                    {summary
                        && <SummarySection title="Integrity">
                            <SummaryRow dataId="database-full-hash" label="Full hash" value={summary.fullHash} />
                        </SummarySection>
                    }
                </>
            }

            {consolidateOpen && databasePath
                && <ConsolidateDatabaseDialog
                    open={consolidateOpen}
                    entry={{ name: databasePath, description: '', path: databasePath }}
                    onClose={() => setConsolidateOpen(false)}
                />
            }
        </>
    );
}
