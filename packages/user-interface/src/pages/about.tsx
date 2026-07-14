import React, { useRef, useState } from "react";
import { version } from "config";
import Box from "@mui/joy/Box";
import Card from "@mui/joy/Card";
import Chip from "@mui/joy/Chip";
import Button from "@mui/joy/Button";
import Input from "@mui/joy/Input";
import Typography from "@mui/joy/Typography";
import Link from "@mui/joy/Link";
import { Check } from "@mui/icons-material";
import { useDeveloper } from "../context/developer-context";
import { useToast } from "../context/toast-context";
import { useIsMobile } from "../lib/use-is-mobile";

//
// Fixed URL of the embedded MCP server in the desktop app. The port is a constant in the
// desktop main process (apps/desktop/src/lib/mcp/main-bridge.ts:MCP_PORT).
//
const MCP_URL = "http://localhost:3475/mcp";

//
// The selling points listed on the about page.
//
const FEATURES = [
    "Local first, so you own it and you control it.",
    "Open source, so you can understand what it does with your files.",
    "Maintain data sovereignty: the storage and privacy of your files are under your control.",
    "Build a corruption resistant database of your digital media files.",
    "Backup your database and keep your backup updated.",
    "Bidirectional synchronization between databases on different devices.",
    "Detect and repair corrupt files.",
    "Securely encrypt files that you store in the cloud vendor of your choice.",
    "Use the GUI to search, view and edit your photos and videos.",
];

export function AboutPage() {
    const [ copyState, setCopyState ] = useState<"idle" | "copied">("idle");
    const { enableDeveloperMode } = useDeveloper();
    const { addToast } = useToast();
    const isMobile = useIsMobile();

    //
    // Running tap state for the hidden developer-mode activation gesture on the version label.
    //
    const tapState = useRef({ count: 0, lastTapTime: 0 });

    //
    // Registers a tap on the version label and enables developer mode after 4 rapid taps,
    // each within 2 seconds of the previous one. A longer gap restarts the streak.
    //
    function onVersionTap(): void {
        const now = Date.now();
        const withinWindow = now - tapState.current.lastTapTime <= 2000;
        const count = withinWindow ? tapState.current.count + 1 : 1;
        if (count >= 4) {
            tapState.current = { count: 0, lastTapTime: now };
            enableDeveloperMode();
            addToast({ message: "Developer mode enabled", color: "success" });
        }
        else {
            tapState.current = { count, lastTapTime: now };
        }
    }

    async function copyMcpUrl(): Promise<void> {
        await navigator.clipboard.writeText(MCP_URL);
        setCopyState("copied");
        setTimeout(() => setCopyState("idle"), 1500);
    }

    return (
        <Box sx={{ width: '100%', height: '100%', overflowY: 'auto', p: isMobile ? 2 : 4, pb: 16 }}>
            <Box sx={{ mx: 'auto', maxWidth: 800 }}>
                <Typography level="h2" sx={{ fontSize: isMobile ? '1.75rem' : '2rem' }}>
                    About Photosphere
                </Typography>

                {/* The version doubles as the hidden developer-mode gesture (four rapid taps), so it
                    is a chip: a real target on a phone rather than a line of grey text. */}
                {/* The version doubles as the hidden developer-mode gesture (four rapid taps), so it
                    is a real button: one element that both carries the text and takes the tap. (A
                    Joy Chip splits those across two elements, which breaks the smoke test that reads
                    the text from the element it clicks.) */}
                <Button
                    data-id="about-version"
                    variant="soft"
                    color="neutral"
                    size={isMobile ? 'lg' : 'sm'}
                    onClick={onVersionTap}
                    sx={{ mt: 1, borderRadius: 'xl', minHeight: isMobile ? 44 : undefined }}
                    >
                    {`Version ${version}`}
                </Button>

                <Typography level="body-md" sx={{ mt: 2.5 }}>
                    Photosphere is a local-first application for managing your database of digital media
                    files (photos and videos). Think of it as the spiritual successor to Picasa, but with
                    a UI more like modern Google Photos, backed by a Git-style database for immutable
                    binary files with editable metadata.
                </Typography>

                <Card variant="soft" sx={{ borderRadius: 'lg', p: 2, mt: 2.5, gap: 1 }}>
                    <Typography level="title-md">Important features</Typography>
                    <Box component="ul" sx={{ m: 0, pl: 2.5, display: 'flex', flexDirection: 'column', gap: 1 }}>
                        {FEATURES.map(feature => (
                            <Typography component="li" level="body-sm" key={feature}>
                                {feature}
                            </Typography>
                        ))}
                    </Box>
                </Card>

                <Card variant="outlined" sx={{ borderRadius: 'lg', p: 2, mt: 2, gap: 1 }}>
                    <Typography level="title-md">Claude / MCP integration</Typography>
                    <Typography level="body-sm">
                        The Photosphere desktop app ships with an embedded Model Context Protocol (MCP)
                        server so AI assistants like Claude Code or Claude Desktop can browse and edit
                        your library while it is open. Add this URL to your MCP client configuration as
                        an HTTP server:
                    </Typography>
                    {/* The copy button sits under the field on a phone, where an end decorator would
                        squeeze the URL into a few characters. */}
                    <Input
                        value={MCP_URL}
                        readOnly
                        size={isMobile ? 'lg' : 'md'}
                        sx={{ fontFamily: 'monospace', maxWidth: isMobile ? '100%' : 500 }}
                        endDecorator={isMobile
                            ? undefined
                            : <Button
                                variant="plain"
                                size="sm"
                                onClick={() => { void copyMcpUrl(); }}
                                >
                                {copyState === "copied" ? "Copied!" : "Copy"}
                            </Button>
                        }
                        />
                    {isMobile
                        && <Button
                            variant="soft"
                            size="lg"
                            startDecorator={copyState === "copied" ? <Check /> : undefined}
                            onClick={() => { void copyMcpUrl(); }}
                            sx={{ minHeight: 48 }}
                            >
                            {copyState === "copied" ? "Copied" : "Copy the URL"}
                        </Button>
                    }
                    <Typography level="body-xs" sx={{ color: 'text.tertiary' }}>
                        The server only accepts connections from this machine and runs only while the
                        Photosphere desktop app is open.
                    </Typography>
                </Card>

                <Box sx={{ mt: 2.5, display: 'flex', flexDirection: 'column', gap: 1 }}>
                    <Typography level="body-sm">
                        {"Photosphere is developed by "}
                        <Link href="https://codecapers.com.au/about" target="_blank">Ashley Davis</Link>.
                    </Typography>
                    <Typography level="body-sm">
                        {"Visit the "}
                        <Link href="https://photosphere.codecapers.com.au/" target="_blank">Photosphere website</Link>
                        {" to learn more."}
                    </Typography>
                    <Typography level="body-sm">
                        {"Early development of Photosphere was covered in the book "}
                        <Link href="https://tfdd.codecapers.com.au/" target="_blank">The Feedback-Driven Developer</Link>.
                    </Typography>
                </Box>
            </Box>
        </Box>
    );
}
