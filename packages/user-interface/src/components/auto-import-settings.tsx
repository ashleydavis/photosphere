import React, { useCallback, useEffect, useState } from "react";
import Box from "@mui/joy/Box";
import Button from "@mui/joy/Button/Button";
import Card from "@mui/joy/Card";
import IconButton from "@mui/joy/IconButton/IconButton";
import Switch from "@mui/joy/Switch/Switch";
import Typography from "@mui/joy/Typography/Typography";
import { Add, CloudUpload, Delete } from "@mui/icons-material";
// Imported from the module rather than the package barrel, which reaches Node-only code.
import { IAutoImportSettings, IFolderAutoImportSource } from "api/src/lib/auto-import-settings";
import { useConfig } from "../context/config-context";
import { usePlatform } from "../context/platform-context";
import { log } from "utils";
import { getDefaultDatabasePath, loadAutoImportSettings, saveAutoImportSettings } from "../lib/auto-import-config";
import { buildCleanupSourcesTaskData, describeCleanupResult, ICleanupSourcesTaskResult } from "../lib/source-cleanup-request";
import { TaskQueue } from "task-queue";
import { RandomUuidGenerator } from "utils";

//
// The source tag the cleanup task is queued under.
//
const CLEANUP_TASK_SOURCE = "source-cleanup";

//
// The "Automatic import" card on the settings page.
//
// Switching it on tells the app to watch the places listed below and import what turns up. The
// places and the toggle are all this card writes: the pacing and the poll interval are not settings
// the user is offered, so they stay at their shared defaults rather than being written out here and
// read back as if they had been chosen.
//
// The card also carries the button that deletes photos this device holds that the database already
// has. That used to be a setting, switched on and off, with automatic import doing the deleting as
// it went: on a phone every deletion raises a system confirmation, so the user was asked once per
// handful of photos. A button asks once, when they choose.
//
export function AutoImportSettings() {
    const config = useConfig();
    const platform = usePlatform();
    const [settings, setSettings] = useState<IAutoImportSettings | undefined>(undefined);

    // How many photos the last counting pass found, or undefined when none has run since the last
    // deletion. This is what turns the button from "find them" into "delete them".
    const [cleanupCounted, setCleanupCounted] = useState<number | undefined>(undefined);

    // What the last cleanup run reported, shown under the button.
    const [cleanupMessage, setCleanupMessage] = useState<string>("");

    // Set while a cleanup is running, so the button shows it is busy and cannot be pressed twice.
    const [cleanupRunning, setCleanupRunning] = useState<boolean>(false);

    useEffect(() => {
        loadAutoImportSettings(config)
            .then(loaded => {
                setSettings(loaded);
                log.event("Automatic import settings loaded");
            })
            .catch(error => log.exception("Failed to load the automatic import settings", error as Error));
    }, [config]);

    //
    // Saves the changed settings and shows them straight away, so the switch does not sit in its old
    // position while the write happens.
    //
    const applySettings = useCallback(async (updated: IAutoImportSettings): Promise<void> => {
        setSettings(updated);
        await saveAutoImportSettings(config, updated);
    }, [config]);

    if (!settings) {
        return <></>;
    }

    //
    // The folders being watched. Only folder sources are shown, because a folder is the only kind of
    // place this platform can watch.
    //
    const folderSources = settings.sources.filter((source): source is IFolderAutoImportSource => source.type === "folder");

    //
    // Adds a folder to watch, chosen through the platform's own folder picker.
    //
    async function addFolder(): Promise<void> {
        const folderPath = await platform.pickFolder({ title: "Choose a folder to watch for new photos" });
        if (!folderPath) {
            return;
        }
        if (folderSources.some(source => source.path === folderPath)) {
            return;
        }

        await applySettings({
            ...settings!,
            sources: [...settings!.sources, { type: "folder", path: folderPath, recurse: true }],
        });
        log.event("Automatic import folder added");
    }

    //
    // Stops watching a folder.
    //
    async function removeFolder(folderPath: string): Promise<void> {
        await applySettings({
            ...settings!,
            sources: settings!.sources.filter(source => source.type !== "folder" || source.path !== folderPath),
        });
        log.event("Automatic import folder removed");
    }

    //
    // Counts the photos on this device the database already holds, then, on a second press, deletes
    // them.
    //
    // Two presses rather than one because this deletes the only copy of a photo that is not in the
    // database, and because a count the user has seen is the only honest way to ask. The counting
    // pass and the deleting pass are the same task with a flag, so what the button offers to delete
    // is decided by exactly the code that then deletes it.
    //
    async function runCleanup(): Promise<void> {
        // Read now rather than when this card was first shown: the database is created when automatic
        // import is switched on, which is usually after this card is on screen, so a path read at
        // mount is empty exactly when the user first wants this button.
        const databasePath = await getDefaultDatabasePath(config);
        if (!databasePath) {
            setCleanupMessage("There is no database to check against yet.");
            return;
        }

        const dryRun = cleanupCounted === undefined;
        setCleanupRunning(true);
        try {
            const queue = new TaskQueue(new RandomUuidGenerator(), CLEANUP_TASK_SOURCE);
            try {
                const taskId = queue.addTask("cleanup-sources", buildCleanupSourcesTaskData(databasePath, settings!, dryRun));
                const taskResult = await queue.awaitTask(taskId);
                const cleanupResult = taskResult?.outputs as ICleanupSourcesTaskResult | undefined;

                setCleanupMessage(describeCleanupResult(cleanupResult, dryRun));
                setCleanupCounted(dryRun && cleanupResult !== undefined && cleanupResult.deletableSourceIds.length > 0
                    ? cleanupResult.deletableSourceIds.length
                    : undefined);
                log.event(dryRun ? "Source cleanup counted" : "Source cleanup ran");
            }
            finally {
                queue.shutdown();
            }
        }
        finally {
            setCleanupRunning(false);
        }
    }

    return (
        <Card
            variant="soft"
            sx={{ borderRadius: 'lg', p: 1.5, gap: 1.5 }}
            data-id="auto-import-card"
            >
            <Box
                data-id="auto-import-toggle"
                sx={{ display: 'flex', alignItems: 'center', gap: 1, cursor: 'pointer' }}
                onClick={() => {
                    const enabled = !settings.enabled;
                    applySettings({ ...settings, enabled })
                        .then(() => log.event(`Automatic import ${enabled ? "enabled" : "disabled"}`))
                        .catch(error => log.exception("Failed to change the automatic import setting", error as Error));
                }}
                >
                <CloudUpload sx={{ color: 'text.secondary' }} />
                <Typography level="title-md" sx={{ flexGrow: 1 }}>Automatic import</Typography>
                <Switch readOnly checked={settings.enabled} sx={{ pointerEvents: 'none' }} />
            </Box>
            <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                Watches the folders below and imports new photos as they appear. The first time this
                is switched on, a private photo database is created for you.
            </Typography>

            <Typography level="title-sm">Folders watched</Typography>
            {folderSources.length === 0
                && <Typography level="body-sm" sx={{ color: 'text.tertiary' }} data-id="auto-import-no-folders">
                    None yet. This machine's own photo folders are used until you add one.
                </Typography>
            }
            {folderSources.map(source => (
                <Box
                    key={source.path}
                    sx={{ display: 'flex', alignItems: 'center', gap: 1 }}
                    data-id={`auto-import-folder-${source.path}`}
                    >
                    <Typography level="body-sm" sx={{ flexGrow: 1, wordBreak: 'break-all' }}>
                        {source.path}
                    </Typography>
                    <IconButton
                        size="sm"
                        variant="plain"
                        color="danger"
                        data-id="auto-import-remove-folder"
                        onClick={() => {
                            removeFolder(source.path)
                                .catch(error => log.exception("Failed to stop watching a folder", error as Error));
                        }}
                        >
                        <Delete />
                    </IconButton>
                </Box>
            ))}
            <Button
                size="sm"
                variant="outlined"
                startDecorator={<Add />}
                data-id="auto-import-add-folder"
                onClick={() => {
                    addFolder().catch(error => log.exception("Failed to add a folder to watch", error as Error));
                }}
                >
                Add a folder
            </Button>

            <Typography level="title-sm">Free up space on this device</Typography>
            <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                Deletes photos from this device that your database already holds. Your database
                becomes the only copy of them, so only do this if you also keep a remote copy.
            </Typography>
            <Button
                size="sm"
                variant="outlined"
                color={cleanupCounted === undefined ? "neutral" : "danger"}
                loading={cleanupRunning}
                data-id="auto-import-cleanup-button"
                onClick={() => {
                    runCleanup().catch(error => log.exception("Failed to clean up source files", error as Error));
                }}
                >
                {cleanupCounted === undefined
                    ? "Find photos already in my database"
                    : `Delete ${cleanupCounted} photo(s) from this device`}
            </Button>
            {cleanupMessage
                && <Typography level="body-sm" sx={{ color: 'text.tertiary' }} data-id="auto-import-cleanup-message">
                    {cleanupMessage}
                </Typography>
            }
        </Card>
    );
}
