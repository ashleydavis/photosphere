import React, { useEffect, useState } from "react";
import Box from "@mui/joy/Box";
import Button from "@mui/joy/Button";
import Card from "@mui/joy/Card";
import CircularProgress from "@mui/joy/CircularProgress";
import Typography from "@mui/joy/Typography";
import { usePlatform, type IToolStatus, type IToolsStatus } from "../context/platform-context";
import { useIsMobile } from "../lib/use-is-mobile";

//
// One row of the tools page: a tool's name and its status.
//
interface IToolRow {
    // The name shown for the tool.
    name: string;

    // Whether the tool ran, its version when it did and its error when it did not.
    status: IToolStatus;
}

//
// The tools page: the versions of the media tools built into Photosphere (ImageMagick, ffprobe and
// ffmpeg), and the error each one gave when it did not run.
//
export function ToolsPage() {
    const platform = usePlatform();
    const isMobile = useIsMobile();

    // The result of the last check, or null while the first one runs.
    const [toolsStatus, setToolsStatus] = useState<IToolsStatus | null>(null);

    //
    // Asks the built-in tools for their versions.
    //
    async function runToolCheck(): Promise<void> {
        setToolsStatus(null);
        setToolsStatus(await platform.checkTools());
    }

    useEffect(() => {
        void runToolCheck();
    // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    const tools: IToolRow[] = toolsStatus === null
        ? []
        : [
            {
                name: "ImageMagick",
                status: toolsStatus.magick,
            },
            {
                name: "ffprobe",
                status: toolsStatus.ffprobe,
            },
            {
                name: "ffmpeg",
                status: toolsStatus.ffmpeg,
            },
        ];

    return (
        <Box data-id="tools-page" sx={{ width: '100%', height: '100%', overflowY: 'auto', p: isMobile ? 2 : 4, pb: 16 }}>
            <Box sx={{ mx: 'auto', maxWidth: 800 }}>
                <Typography level="h2" sx={{ fontSize: isMobile ? '1.75rem' : '2rem' }}>
                    Tools
                </Typography>
                <Typography level="body-md" sx={{ mt: 2.5 }}>
                    Photosphere reads photos and videos with the media tools built into it.
                </Typography>

                {toolsStatus === null && (
                    <CircularProgress size="md" sx={{ mt: 2.5 }} />
                )}

                {toolsStatus !== null && (
                    <Card variant="soft" sx={{ borderRadius: 'lg', p: 2, mt: 2.5, gap: 1 }}>
                        {tools.map(tool => (
                            <Typography key={tool.name} data-id={`tool-${tool.name.toLowerCase()}`} level="body-sm">
                                <b>{tool.name}</b>
                                {": "}
                                {tool.status.available
                                    ? tool.status.version ?? "No version was reported."
                                    : `Did not run. ${tool.status.error ?? "No error was reported."}`}
                            </Typography>
                        ))}
                    </Card>
                )}

                {toolsStatus !== null && !toolsStatus.allAvailable && (
                    <Button variant="soft" color="neutral" onClick={() => { void runToolCheck(); }} sx={{ mt: 2 }}>
                        Check again
                    </Button>
                )}
            </Box>
        </Box>
    );
}
