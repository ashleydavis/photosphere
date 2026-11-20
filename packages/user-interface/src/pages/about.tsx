import React, { useRef, useState } from "react";
import { version } from "config";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import OutlinedInput from "@mui/material/OutlinedInput";
import InputAdornment from "@mui/material/InputAdornment";
import Typography from "@mui/material/Typography";
import Link from "@mui/material/Link";
import { Check, LocalOffer, Link as LinkIcon } from "@mui/icons-material";
import { useDeveloper } from "../context/developer-context";
import { useToast } from "../context/toast-context";
import { useIsMobile } from "../lib/use-is-mobile";

//
// Fixed URL of the embedded MCP server in the desktop app. The port was a constant in the
// Electron app's main process, which has been removed.
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

    //
    // The surface of each card on the page: a panel on the page with the raised shadow, as the
    // style guide's About page draws its feature and MCP cards.
    //
    const cardSx = {
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--space-3)',
        padding: isMobile ? 'var(--space-4)' : 'var(--space-6)',
        background: 'var(--color-panel)',
        border: '1px solid var(--color-border)',
        borderRadius: 'var(--radius-md)',
        boxShadow: 'var(--shadow-raised)',
    };

    //
    // The heading of each card on the page.
    //
    const cardTitleSx = {
        fontSize: 'var(--text-lg)',
        fontWeight: 'var(--weight-bold)',
        lineHeight: 'var(--leading-tight)',
    };

    return (
        <Box sx={{ width: '100%', height: '100%', overflowY: 'auto' }}>
            <Box
                sx={{
                    display: 'flex',
                    flexDirection: 'column',
                    gap: isMobile ? 'var(--space-4)' : 'var(--space-6)',
                    mx: 'auto',
                    maxWidth: 'calc(var(--space-8) * 30)',
                    padding: isMobile ? 'var(--space-4) var(--space-4) calc(var(--space-8) * 4)' : 'var(--space-6) var(--space-6) calc(var(--space-8) * 4)',
                }}
                >
                <Typography
                    variant="h2"
                    sx={{
                        fontFamily: 'var(--font-heading)',
                        fontSize: 'var(--page-title-size)',
                        fontWeight: 'var(--weight-bold)',
                        lineHeight: 'var(--leading-tight)',
                    }}
                    >
                    About Photosphere
                </Typography>

                <Box
                    component="section"
                    aria-label="Photosphere"
                    sx={{
                        display: 'flex',
                        flexDirection: 'column',
                        alignItems: 'center',
                        gap: 'var(--space-3)',
                        padding: 'var(--space-4)',
                        textAlign: 'center',
                    }}
                    >
                    {/* The logo mark: the brand gradient as a sphere, lit at its upper left. It is
                        decoration where the user is welcomed, as the style guide allows. */}
                    <Box
                        aria-hidden={true}
                        sx={{
                            width: 'calc(var(--space-8) * 3)',
                            height: 'calc(var(--space-8) * 3)',
                            borderRadius: 'var(--radius-full)',
                            background: 'radial-gradient(circle at 32% 28%, color-mix(in srgb, var(--color-empty-icon) 35%, transparent), transparent 45%), linear-gradient(135deg, var(--color-brand-start), var(--color-brand-middle) 55%, var(--color-brand-end))',
                            boxShadow: 'var(--shadow-overlay)',
                        }}
                        />

                    {/* The version doubles as the hidden developer-mode gesture (four rapid taps), so
                        it is a real button: one element that both carries the text and takes the
                        tap. (A chip splits those across two elements, which breaks the smoke test
                        that reads the text from the element it clicks.) */}
                    <Button
                        data-id="about-version"
                        variant="outlined"
                        size={isMobile ? 'large' : 'small'}
                        startIcon={<LocalOffer />}
                        onClick={onVersionTap}
                        >
                        {`Version ${version}`}
                    </Button>

                    <Typography
                        variant="body1"
                        sx={{
                            maxWidth: 'calc(var(--space-8) * 17)',
                            color: 'var(--color-text-muted)',
                        }}
                        >
                        Photosphere is a local-first application for managing your database of digital media
                        files (photos and videos). Think of it as the spiritual successor to Picasa, but with
                        a UI more like modern Google Photos, backed by a Git-style database for immutable
                        binary files with editable metadata.
                    </Typography>
                </Box>

                <Box component="section" aria-label="Important features" sx={cardSx}>
                    <Typography variant="subtitle1" sx={cardTitleSx}>Important features</Typography>
                    <Box
                        component="ul"
                        sx={{
                            display: 'grid',
                            gridTemplateColumns: {
                                xs: 'minmax(0, 1fr)',
                                sm: 'var(--feature-columns)',
                            },
                            gap: 'var(--space-4)',
                            margin: 0,
                            padding: 0,
                            listStyle: 'none',
                        }}
                        >
                        {FEATURES.map(feature => (
                            <Typography
                                component="li"
                                variant="body2"
                                key={feature}
                                sx={{
                                    padding: 'var(--feature-padding)',
                                    background: 'var(--feature-card-bg)',
                                    boxShadow: 'inset 0 0 0 1px var(--feature-card-border-color)',
                                    borderRadius: 'var(--radius-md)',
                                    fontSize: 'var(--text-sm)',
                                }}
                                >
                                {feature}
                            </Typography>
                        ))}
                    </Box>
                </Box>

                <Box component="section" aria-label="Claude / MCP integration" sx={cardSx}>
                    <Typography variant="subtitle1" sx={cardTitleSx}>Claude / MCP integration</Typography>
                    <Typography variant="body2" sx={{ color: 'var(--color-text-muted)' }}>
                        The Photosphere desktop app ships with an embedded Model Context Protocol (MCP)
                        server so AI assistants like Claude Code or Claude Desktop can browse and edit
                        your library while it is open. Add this URL to your MCP client configuration as
                        an HTTP server:
                    </Typography>
                    {/* The copy button sits under the field on a mobile, where a button beside it
                        would squeeze the URL into a few characters. */}
                    <Box
                        sx={{
                            display: 'flex',
                            flexDirection: isMobile ? 'column' : 'row',
                            alignItems: isMobile ? 'stretch' : 'center',
                            gap: 'var(--space-2)',
                        }}
                        >
                        <OutlinedInput
                            value={MCP_URL}
                            readOnly
                            size={isMobile ? 'medium' : 'small'}
                            fullWidth
                            startAdornment={
                                <InputAdornment position="start">
                                    <LinkIcon />
                                </InputAdornment>
                            }
                            sx={{
                                fontFamily: 'var(--font-mono)',
                                fontSize: 'var(--text-sm)',
                            }}
                            />
                        {isMobile
                            ? <Button
                                variant="outlined"
                                size="large"
                                startIcon={copyState === "copied" ? <Check /> : undefined}
                                onClick={() => { void copyMcpUrl(); }}
                                >
                                {copyState === "copied" ? "Copied" : "Copy the URL"}
                            </Button>
                            : <Button
                                variant="contained"
                                onClick={() => { void copyMcpUrl(); }}
                                sx={{
                                    flex: 'none',
                                    minWidth: 'calc(var(--space-8) * 3)',
                                }}
                                >
                                {copyState === "copied" ? "Copied!" : "Copy"}
                            </Button>
                        }
                    </Box>
                    <Typography
                        variant="caption"
                        sx={{
                            color: 'var(--color-text-muted)',
                            fontSize: 'var(--text-sm)',
                        }}
                        >
                        The server only accepts connections from this machine and runs only while the
                        Photosphere desktop app is open.
                    </Typography>
                </Box>

                <Box
                    component="footer"
                    sx={{
                        display: 'flex',
                        flexDirection: 'column',
                        alignItems: 'center',
                        gap: 'var(--space-2)',
                        textAlign: 'center',
                        color: 'var(--color-text-muted)',
                        '& .MuiTypography-root': {
                            fontSize: 'var(--text-sm)',
                        },
                        '& .MuiLink-root': {
                            color: 'var(--color-accent)',
                            textDecorationColor: 'currentColor',
                        },
                    }}
                    >
                    <Typography variant="body2">
                        {"Photosphere is developed by "}
                        <Link href="https://codecapers.com.au/about" target="_blank" underline="hover">Ashley Davis</Link>.
                    </Typography>
                    <Typography variant="body2">
                        {"Visit the "}
                        <Link href="https://photosphere.codecapers.com.au/" target="_blank" underline="hover">Photosphere website</Link>
                        {" to learn more."}
                    </Typography>
                    <Typography variant="body2">
                        {"Early development of Photosphere was covered in the book "}
                        <Link href="https://tfdd.codecapers.com.au/" target="_blank" underline="hover">The Feedback-Driven Developer</Link>.
                    </Typography>
                </Box>
            </Box>
        </Box>
    );
}
