import React, { useEffect, useRef, useState } from "react";
import { TaskQueue, TaskStatus } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { useAssetDatabase } from "../context/asset-database-source";
import type { IDatabaseSummary } from "api";
import type { IGetDatabaseSummaryData } from "api";

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
// Props for a single labelled row in the summary table.
//
interface ISummaryRowProps {
    // Label for the row.
    label: string;

    // Value to display.
    value: string;
}

//
// Renders a single labelled row in the summary.
//
function SummaryRow({ label, value }: ISummaryRowProps) {
    return (
        <div className="flex flex-row py-2 border-b border-gray-200 dark:border-gray-700">
            <span className="w-48 font-medium text-gray-500 dark:text-gray-400 shrink-0">{label}</span>
            <span className="font-mono break-all">{value}</span>
        </div>
    );
}

//
// Page that displays summary information about the currently open database.
//
export function DatabaseSummaryPage() {
    const { databasePath } = useAssetDatabase();

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

        queue.current = new TaskQueue(new RandomUuidGenerator(), `database-summary-${databasePath}`);

        const taskData: IGetDatabaseSummaryData = { databasePath };
        const taskId = queue.current.addTask("get-database-summary", taskData);

        queue.current.awaitTask(taskId).then(result => {
            if (!result) {
                return;
            }
            if (result.status === TaskStatus.Succeeded) {
                setSummary(result.outputs as IDatabaseSummary);
            }
            else {
                setError(result.errorMessage || "Failed to load database summary");
            }
            setIsLoading(false);
        });

        return () => {
            queue.current?.shutdown();
            queue.current = undefined;
        };
    }, [databasePath]);

    return (
        <div className="w-full h-full p-4 overflow-y-auto pb-32">
            <div className="m-auto" style={{ maxWidth: "800px" }}>
                <h1 className="mt-6 text-3xl">Summary</h1>

                {!databasePath && (
                    <p className="pt-4 text-gray-500">No database is currently open.</p>
                )}

                {databasePath && (
                    <>
                        <div className="pt-6">
                            <h2 className="text-xl font-semibold mb-3">Location</h2>
                            <SummaryRow label="Path" value={databasePath} />
                            <SummaryRow label="Storage type" value={getStorageType(databasePath)} />
                        </div>

                        {isLoading && (
                            <p className="pt-6 text-gray-500">Loading summary...</p>
                        )}

                        {error && (
                            <p className="pt-6 text-red-500">{error}</p>
                        )}

                        {summary && (
                            <>
                                <div className="pt-6">
                                    <h2 className="text-xl font-semibold mb-3">Statistics</h2>
                                    <SummaryRow label="Files imported" value={summary.totalImports.toLocaleString()} />
                                    <SummaryRow label="Total files" value={summary.totalFiles.toLocaleString()} />
                                    <SummaryRow label="Total size" value={formatBytes(summary.totalSize)} />
                                    <SummaryRow label="Database version" value={summary.databaseVersion.toString()} />
                                </div>

                                <div className="pt-6">
                                    <h2 className="text-xl font-semibold mb-3">Integrity</h2>
                                    {summary.filesHash && (
                                        <SummaryRow label="Files hash" value={summary.filesHash} />
                                    )}
                                    {summary.databaseHash && (
                                        <SummaryRow label="Database hash" value={summary.databaseHash} />
                                    )}
                                    <SummaryRow label="Full hash" value={summary.fullHash} />
                                </div>
                            </>
                        )}
                    </>
                )}
            </div>
        </div>
    );
}
