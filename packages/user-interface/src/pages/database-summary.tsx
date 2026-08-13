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
import { useIsMobile } from "../lib/use-is-mobile";
import type { IDatabaseSummary } from "node-api";
import type { IGetDatabaseSummaryData } from "node-api";
import Button from "@mui/joy/Button";
import { ConsolidateDatabaseDialog } from "../components/consolidate-database-dialog";

//
// Formats a byte count into a human-readable string (e.g. "1.5 GiB").
//
function formatBytes(bytes: number): string {
    if (bytes === 0) {
        return "0 Bytes";
    }
    const units = ["Bytes", "KiB", "MiB", "GiB", "TiB"];
    const index = Math.floor(Math.log(bytes) / Math.log(1024));
    const value = bytes / Math.pow(1024, index);
    const formatted = value >= 100 || value % 1 === 0
        ? Math.round(value).toLocaleString()
        : value.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
    return `${formatted} ${units[index]}`;
}

//
// Determines the storage type label from a database path.
//
function getStorageType(databasePath: string): string {
    if (databasePath.startsWith("s3:")) {
        return "S3-compatible object storage";
    }
    return "Local filesystem";
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
// A single headline statistic, shown as a tile with the number given real size. On a phone this is
// what the page is for: the numbers should be readable at arm's length, not buried in a label/value
// table built for a wide screen.
//
function StatTile({ label, value, icon }: IStatTileProps) {
    return (
        <Card
            variant="soft"
            sx={{ borderRadius: 'lg', p: 2, gap: 0.5, flex: '1 1 140px', minWidth: 140 }}
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
// Page that displays summary information about the currently open database.
//
export function DatabaseSummaryPage() {
    const { databasePath } = useAssetDatabase();
    const uuidGenerator = useUuidGenerator();
    const isMobile = useIsMobile();

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

        queue.current = new TaskQueue(uuidGenerator, `database-summary-${databasePath}`);

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
        <Box sx={{ width: '100%', height: '100%', overflowY: 'auto', p: isMobile ? 2 : 4, pb: 16 }}>
            <Box sx={{ mx: 'auto', maxWidth: 800 }}>
                <Typography level="h2" sx={{ fontSize: isMobile ? '1.75rem' : '2rem', mb: 2 }}>
                    Summary
                </Typography>

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

                        {summary
                            && <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 1.5 }}>
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
                                {summary.filesHash
                                    && <SummaryRow dataId="database-files-hash" label="Files hash" value={summary.filesHash} />
                                }
                                {summary.databaseHash
                                    && <SummaryRow dataId="database-database-hash" label="Database hash" value={summary.databaseHash} />
                                }
                                <SummaryRow dataId="database-full-hash" label="Full hash" value={summary.fullHash} />
                            </SummarySection>
                        }
                    </>
                }
            </Box>

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
