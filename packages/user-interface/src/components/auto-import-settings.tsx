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
import { loadAutoImportSettings, saveAutoImportSettings } from "../lib/auto-import-config";

//
// The "Automatic import" card on the settings page.
//
// Switching it on tells the app to watch the places listed below and import what turns up. The
// places, the toggle and the cleanup setting are all this card writes: the pacing and the poll
// interval are not settings the user is offered, so they stay at their shared defaults rather than
// being written out here and read back as if they had been chosen.
//
export function AutoImportSettings() {
    const config = useConfig();
    const platform = usePlatform();
    const [settings, setSettings] = useState<IAutoImportSettings | undefined>(undefined);

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

            <Box
                data-id="auto-import-cleanup-toggle"
                sx={{ display: 'flex', alignItems: 'center', gap: 1, cursor: 'pointer' }}
                onClick={() => {
                    const cleanupEnabled = !settings.cleanupEnabled;
                    applySettings({ ...settings, cleanupEnabled })
                        .then(() => log.event(`Automatic import cleanup ${cleanupEnabled ? "enabled" : "disabled"}`))
                        .catch(error => log.exception("Failed to change the cleanup setting", error as Error));
                }}
                >
                <Typography level="title-sm" sx={{ flexGrow: 1 }}>Delete originals after import</Typography>
                <Switch readOnly checked={settings.cleanupEnabled} sx={{ pointerEvents: 'none' }} />
            </Box>
            <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                Deletes each file from the watched folder once the photo is confirmed in your
                database. Your database becomes the only copy, so leave this off unless you also keep
                a remote copy.
            </Typography>
        </Card>
    );
}
