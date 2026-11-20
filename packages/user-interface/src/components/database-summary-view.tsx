import React, { useEffect, useRef, useState } from "react";
import { log } from "utils";
import { TaskQueue, TaskStatus } from "task-queue";
import Box from "@mui/material/Box";
import Typography from "@mui/material/Typography";
import CircularProgress from "@mui/material/CircularProgress";
import Alert from "@mui/material/Alert";
import { Storage, Photo, Folder, Save, CloudSync, LocationOn, Shield } from "@mui/icons-material";
import { useAssetDatabase } from "../context/asset-database-source";
import { useUuidGenerator } from "../context/uuid-generator-context";
import { formatBytes, getStorageType } from "../lib/database-summary-format";
import Button from "@mui/material/Button";
import { ConsolidateDatabaseDialog } from "./consolidate-database-dialog";

//
// Whether the database holds every asset or only a partial set.
// "partial" means only the thumb directory's assets are present locally and the rest are fetched
// lazily from the database's origin.
//
type DatabaseMode = "full" | "partial";

//
// Summary of a database, as computed by the get-database-summary task.
//
interface IDatabaseSummary {
    //
    // Whether this database is a full copy or a partial replica.
    //
    mode: DatabaseMode;

    //
    // Total number of files imported into the database.
    //
    totalImports: number;

    //
    // Total number of files in the database (including thumbnails, display images, BSON files, etc.).
    //
    totalFiles: number;

    //
    // Total size of all files in bytes.
    //
    totalSize: number;

    //
    // Total number of nodes in the merkle tree.
    //
    totalNodes: number;

    //
    // Full hash of the tree root.
    //
    fullHash: string;

    //
    // Root hash of the files merkle tree.
    //
    filesHash: string | undefined;

    //
    // Root hash of the BSON database merkle tree.
    //
    databaseHash: string | undefined;

    //
    // Database version from merkle tree.
    //
    databaseVersion: number;
}

//
// Input data for the get-database-summary task.
//
interface IGetDatabaseSummaryData {
    //
    // Filesystem path (or S3 path) to the database directory.
    //
    databasePath: string;
}

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
// A single headline statistic, shown as a tile with the number given real size. On a mobile this is
// what the page is for: the numbers should be readable at arm's length, not buried in a label/value
// table built for a wide screen. The icon sits on the summary's stat icon square, the one place the
// brand gradient greets the user on this page.
//
function StatTile({ label, value, icon }: IStatTileProps) {
    return (
        <Box
            sx={{
                display: 'flex',
                alignItems: 'center',
                gap: 'var(--space-4)',
                padding: 'var(--space-4)',
                minWidth: 0,
                background: 'var(--color-panel)',
                border: '1px solid var(--color-border)',
                borderRadius: 'var(--radius-md)',
                boxShadow: 'var(--shadow-raised)',
            }}
            >
            <Box
                aria-hidden={true}
                sx={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    flex: 'none',
                    width: 'calc(var(--space-8) + var(--space-4))',
                    height: 'calc(var(--space-8) + var(--space-4))',
                    background: 'var(--stat-icon-bg)',
                    color: 'var(--stat-icon-color)',
                    boxShadow: 'inset 0 0 0 1px var(--stat-icon-border-color)',
                    borderRadius: 'var(--radius-md)',
                    fontSize: 'var(--text-xl)',
                    '& .MuiSvgIcon-root': {
                        fontSize: 'inherit',
                    },
                }}
                >
                {icon}
            </Box>
            <Box
                sx={{
                    display: 'flex',
                    flexDirection: 'column',
                    minWidth: 0,
                }}
                >
                <Typography
                    variant="body2"
                    sx={{
                        color: 'var(--color-text-muted)',
                        fontSize: 'var(--text-sm)',
                    }}
                    >
                    {label}
                </Typography>
                <Typography
                    variant="h2"
                    sx={{
                        fontFamily: 'var(--font-sans)',
                        fontSize: 'var(--text-2xl)',
                        fontWeight: 'var(--weight-bold)',
                        lineHeight: 'var(--leading-tight)',
                        fontVariantNumeric: 'tabular-nums',
                        overflowWrap: 'anywhere',
                    }}
                    >
                    {value}
                </Typography>
            </Box>
        </Box>
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
// side-by-side row leaves a mobile with a 48px-wide column for a value that is often a long path or
// a 64-character hash.
//
function SummaryRow({ dataId, label, value }: ISummaryRowProps) {
    return (
        <Box
            data-id={dataId}
            sx={{
                display: 'flex',
                flexDirection: 'column',
                gap: 'var(--space-1)',
            }}
            >
            <Typography
                variant="caption"
                sx={{
                    color: 'var(--color-text-muted)',
                    fontSize: 'var(--text-sm)',
                }}
                >
                {label}
            </Typography>
            <Typography
                variant="body2"
                sx={{
                    padding: 'var(--mono-value-padding)',
                    background: 'var(--mono-value-bg)',
                    boxShadow: 'inset 0 0 0 1px var(--mono-value-border-color)',
                    borderRadius: 'var(--radius-sm)',
                    fontFamily: 'var(--font-mono)',
                    fontSize: 'var(--text-sm)',
                    overflowWrap: 'anywhere',
                }}
                >
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

    // Icon shown in the accent colour beside the heading.
    icon: React.ReactNode;

    // The rows in the group.
    children: React.ReactNode | React.ReactNode[];
}

//
// A titled group of detail rows, presented as a card with its icon in the accent colour beside its
// title.
//
function SummarySection({ title, icon, children }: ISummarySectionProps) {
    return (
        <Box
            component="section"
            aria-label={title}
            sx={{
                display: 'flex',
                flexDirection: 'column',
                gap: 'var(--space-3)',
                minWidth: 0,
                padding: 'var(--space-4)',
                background: 'var(--color-panel)',
                border: '1px solid var(--color-border)',
                borderRadius: 'var(--radius-md)',
                boxShadow: 'var(--shadow-raised)',
            }}
            >
            <Typography
                variant="subtitle1"
                sx={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 'var(--space-2)',
                    fontSize: 'var(--text-lg)',
                    fontWeight: 'var(--weight-bold)',
                    lineHeight: 'var(--leading-tight)',
                    '& .MuiSvgIcon-root': {
                        color: 'var(--color-accent)',
                        fontSize: 'var(--icon-lg)',
                    },
                }}
                >
                {icon}
                {title}
            </Typography>
            {children}
        </Box>
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
        <Box
            sx={{
                display: 'flex',
                flexDirection: 'column',
                gap: 'var(--space-4)',
            }}
            >
            {!databasePath
                && <Typography variant="body1" sx={{ color: 'var(--color-text-muted)' }}>
                    No database is currently open.
                </Typography>
            }

            {databasePath
                && <>
                    {isLoading
                        && <Box
                            sx={{
                                display: 'flex',
                                alignItems: 'center',
                                gap: 'var(--space-3)',
                                padding: 'var(--space-6) 0',
                            }}
                            >
                            <CircularProgress size="var(--icon-lg)" />
                            <Typography variant="body1" sx={{ color: 'var(--color-text-muted)' }}>
                                Loading summary...
                            </Typography>
                        </Box>
                    }

                    {error
                        && <Alert severity="error" icon={false}>
                            <Typography variant="body1">{error}</Typography>
                        </Alert>
                    }

                    {/*
                        Two fixed columns rather than a wrapping flex row. Wrapping stretched
                        whatever landed on the last row to the full width, so the fourth tile read
                        as a banner across the modal instead of one of four. Two columns put the
                        four stats in a square, and no tile is ever left alone on a row of its own.
                        Below the small breakpoint the tiles stack in one column, as the style
                        guide's summary does, so each number keeps its full size.
                    */}
                    {summary
                        && <Box
                            sx={{
                                display: 'grid',
                                gridTemplateColumns: {
                                    xs: 'minmax(0, 1fr)',
                                    sm: 'repeat(2, minmax(0, 1fr))',
                                },
                                gap: 'var(--space-3)',
                            }}
                            >
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

                    {/*
                        Location and Integrity sit side by side where both fit, as on the style
                        guide's summary, and stack where they do not.
                    */}
                    <Box
                        sx={{
                            display: 'grid',
                            gridTemplateColumns: 'repeat(auto-fit, minmax(calc(var(--space-8) * 9), 1fr))',
                            gap: 'var(--space-4)',
                        }}
                        >
                        <SummarySection title="Location" icon={<LocationOn />}>
                            <SummaryRow dataId="database-path" label="Path" value={databasePath} />
                            <SummaryRow dataId="database-storage-type" label="Storage type" value={getStorageType(databasePath)} />
                            {summary
                                && <SummaryRow dataId="database-mode" label="Mode" value={summary.mode} />
                            }
                        </SummarySection>

                        {summary
                            && <SummarySection title="Integrity" icon={<Shield />}>
                                <SummaryRow dataId="database-full-hash" label="Full hash" value={summary.fullHash} />
                            </SummarySection>
                        }
                    </Box>

                    <SummarySection title="Remote copy" icon={<CloudSync />}>
                        <Typography variant="body2" sx={{ color: 'var(--color-text-muted)' }}>
                            Keeps a copy of this database on a remote. If the remote already holds a
                            different database, the two are joined and nothing it already has is
                            uploaded again.
                        </Typography>
                        <Button
                            variant="outlined"
                            startIcon={<CloudSync />}
                            sx={{
                                alignSelf: 'flex-start',
                            }}
                            data-id="summary-consolidate-database-button"
                            onClick={() => { log.info('Consolidate into remote dialog opened'); setConsolidateOpen(true); }}
                            >
                            Consolidate into remote
                        </Button>
                    </SummarySection>
                </>
            }

            {consolidateOpen && databasePath
                && <ConsolidateDatabaseDialog
                    open={consolidateOpen}
                    entry={{ name: databasePath, description: '', path: databasePath }}
                    onClose={() => setConsolidateOpen(false)}
                />
            }
        </Box>
    );
}
