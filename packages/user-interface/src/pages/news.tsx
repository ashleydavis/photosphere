import React, { useEffect, useState } from "react";
import { version } from "config";
import Box from "@mui/material/Box";
import Chip from "@mui/material/Chip";
import Button from "@mui/material/Button";
import Typography from "@mui/material/Typography";
import Link from "@mui/material/Link";
import CircularProgress from "@mui/material/CircularProgress";
import { Download, OpenInNew, CardGiftcard, ArrowUpward, Check } from "@mui/icons-material";
import { useApi } from "../context/api-context";
import { useIsMobile } from "../lib/use-is-mobile";

//
// URL of the GitHub API endpoint that returns the latest non-prerelease release.
//
const LATEST_RELEASE_URL = 'https://api.github.com/repos/ashleydavis/photosphere/releases/latest';

//
// URL of the published news feed.
//
const NEWS_FEED_URL = 'https://raw.githubusercontent.com/ashleydavis/photosphere/main/news.yaml';

//
// A labelled URL used as either an inline link or a CTA action on a news item.
//
interface INewsLink {
    //
    // Visible label.
    //
    label: string;

    //
    // External URL opened when the label is clicked.
    //
    url: string;
}

//
// A single news item parsed from the published news.yaml feed.
//
interface INewsItem {
    //
    // Stable item id.
    //
    id: string;

    //
    // Message body.
    //
    message: string;

    //
    // Optional inline link displayed below the message.
    //
    link?: INewsLink;

    //
    // Optional CTA action displayed below the message.
    //
    action?: INewsLink;
}

//
// Naive YAML parser scoped to the published news.yaml shape: a top-level `items:` list
// containing entries with id, message, optional link, optional action. Returns the parsed
// items, or an empty array on any parse failure. Lives in the page so the renderer does
// not need to ship a full YAML library for this single use.
//
function parseNewsYaml(text: string): INewsItem[] {
    const items: INewsItem[] = [];
    const lines = text.split('\n');
    let current: Partial<INewsItem> | undefined;
    let nested: 'link' | 'action' | undefined;

    function stripQuotes(value: string): string {
        const trimmed = value.trim();
        if ((trimmed.startsWith('"') && trimmed.endsWith('"'))
            || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
            return trimmed.slice(1, -1);
        }
        return trimmed;
    }

    for (const rawLine of lines) {
        const line = rawLine.replace(/\r$/, '');
        if (line.length === 0 || line.trimStart().startsWith('#')) {
            continue;
        }
        const trimmed = line.trim();
        if (line.startsWith('  - ')) {
            if (current && current.id && current.message) {
                items.push(current as INewsItem);
            }
            current = {};
            nested = undefined;
            const firstField = trimmed.slice(2);
            const colonIndex = firstField.indexOf(':');
            if (colonIndex >= 0) {
                const key = firstField.slice(0, colonIndex).trim();
                const value = stripQuotes(firstField.slice(colonIndex + 1));
                if (key === 'id') {
                    current.id = value;
                }
                else if (key === 'message') {
                    current.message = value;
                }
            }
            continue;
        }
        if (current === undefined) {
            continue;
        }
        const colonIndex = trimmed.indexOf(':');
        if (colonIndex < 0) {
            continue;
        }
        const key = trimmed.slice(0, colonIndex).trim();
        const value = stripQuotes(trimmed.slice(colonIndex + 1));
        if (line.startsWith('    ') && !line.startsWith('      ')) {
            if (value.length === 0 && (key === 'link' || key === 'action')) {
                nested = key;
                continue;
            }
            nested = undefined;
            if (key === 'id') {
                current.id = value;
            }
            else if (key === 'message') {
                current.message = value;
            }
        }
        else if (line.startsWith('      ') && nested) {
            const link = current[nested] ?? { label: '', url: '' };
            if (key === 'label') {
                link.label = value;
            }
            else if (key === 'url') {
                link.url = value;
            }
            current[nested] = link;
        }
    }
    if (current && current.id && current.message) {
        items.push(current as INewsItem);
    }
    return items;
}

//
// Top-level News page. Shows the running build version, the latest available GitHub
// release (when known), and the published news feed (newest-first). Fetches both
// directly from GitHub on mount; no main-process IPC is involved.
//
export function NewsPage() {
    const api = useApi();
    const isMobile = useIsMobile();
    const [latestVersion, setLatestVersion] = useState<string | undefined>(undefined);
    const [items, setItems] = useState<INewsItem[]>([]);
    const [loading, setLoading] = useState<boolean>(true);

    useEffect(() => {
        let cancelled = false;
        async function load() {
            const versionPromise = api.get(LATEST_RELEASE_URL).then((response) => {
                const data = response.data as { tag_name?: string };
                if (!data.tag_name || typeof data.tag_name !== 'string') {
                    return undefined;
                }
                return data.tag_name.startsWith('v')
                    ? data.tag_name.slice(1)
                    : data.tag_name;
            }).catch(() => undefined);

            const feedPromise = api.get(NEWS_FEED_URL, { responseType: "text" }).then((response) => {
                return parseNewsYaml(response.data as string);
            }).catch(() => [] as INewsItem[]);

            const [resolvedVersion, resolvedItems] = await Promise.all([versionPromise, feedPromise]);
            if (cancelled) {
                return;
            }
            setLatestVersion(resolvedVersion);
            setItems(resolvedItems);
            setLoading(false);
        }
        void load();
        return () => {
            cancelled = true;
        };
    }, [api]);

    const runningVersion = version;
    const hasUpdate = latestVersion !== undefined && latestVersion !== runningVersion;
    const orderedItems = [...items].reverse();

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
                    News
                </Typography>

                {/* The version card leads with whether there is an update, because that is the one
                    thing anybody opens this page to find out. The download is a full-width button
                    on a mobile rather than an underlined link. */}
                <Box
                    component="section"
                    aria-label="Version"
                    sx={{
                        display: 'flex',
                        flexWrap: 'wrap',
                        alignItems: 'center',
                        gap: 'var(--space-4)',
                        padding: 'var(--space-4)',
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
                            width: 'calc(var(--space-8) + var(--space-6))',
                            height: 'calc(var(--space-8) + var(--space-6))',
                            background: 'var(--empty-icon-bg)',
                            color: 'var(--color-empty-icon)',
                            borderRadius: 'var(--radius-md)',
                            fontSize: 'var(--text-xl)',
                        }}
                        >
                        <CardGiftcard fontSize="inherit" />
                    </Box>
                    <Box
                        sx={{
                            display: 'flex',
                            flexDirection: 'column',
                            gap: 'var(--space-1)',
                            flex: 1,
                            minWidth: 'calc(var(--space-8) * 6)',
                        }}
                        >
                        <Box
                            sx={{
                                display: 'flex',
                                alignItems: 'center',
                                flexWrap: 'wrap',
                                gap: 'var(--space-2)',
                            }}
                            >
                            <Typography
                                variant="subtitle1"
                                sx={{
                                    fontSize: 'var(--text-lg)',
                                    fontWeight: 'var(--weight-bold)',
                                }}
                                >
                                {`Version v${runningVersion}`}
                            </Typography>
                            {latestVersion !== undefined
                                && <Chip
                                    size="small"
                                    icon={hasUpdate ? <ArrowUpward /> : <Check />}
                                    label={hasUpdate ? 'Update available' : 'Up to date'}
                                    sx={{
                                        minHeight: 'var(--space-6)',
                                        fontSize: 'var(--text-xs)',
                                        fontWeight: 'var(--weight-bold)',
                                        background: hasUpdate ? 'color-mix(in srgb, var(--color-success) 14%, transparent)' : 'var(--color-raised)',
                                        borderColor: hasUpdate ? 'color-mix(in srgb, var(--color-success) 45%, transparent)' : 'var(--color-border)',
                                        color: hasUpdate ? 'var(--color-success)' : 'var(--color-text-muted)',
                                        '& .MuiChip-icon': {
                                            fontSize: 'var(--icon-sm)',
                                            color: 'inherit',
                                            marginLeft: 'var(--space-2)',
                                        },
                                    }}
                                    />
                            }
                        </Box>

                        {latestVersion !== undefined
                            && <Typography
                                variant="body2"
                                sx={{
                                    color: 'var(--color-text-muted)',
                                    fontSize: 'var(--text-sm)',
                                }}
                                >
                                {`Latest release: v${latestVersion}`}
                            </Typography>
                        }
                    </Box>

                    {hasUpdate
                        && <Button
                            component="a"
                            href="https://github.com/ashleydavis/photosphere/releases/latest"
                            target="_blank"
                            rel="noopener noreferrer"
                            variant="contained"
                            fullWidth={isMobile}
                            startIcon={<Download />}
                            >
                            Download the latest release
                        </Button>
                    }
                </Box>

                <Box
                    component="section"
                    aria-label="News items"
                    sx={{
                        display: 'flex',
                        flexDirection: 'column',
                        gap: 'var(--space-3)',
                    }}
                    >
                    <Typography
                        variant="h6"
                        sx={{
                            fontSize: 'var(--text-lg)',
                            fontWeight: 'var(--weight-bold)',
                        }}
                        >
                        News items
                    </Typography>

                    {loading
                        && <Box
                            sx={{
                                display: 'flex',
                                alignItems: 'center',
                                gap: 'var(--space-3)',
                                padding: 'var(--space-4) 0',
                            }}
                            >
                            <CircularProgress size="var(--icon-lg)" />
                            <Typography variant="body1" sx={{ color: 'var(--color-text-muted)' }}>Loading...</Typography>
                        </Box>
                    }

                    {!loading && orderedItems.length === 0
                        && <Typography variant="body1" sx={{ color: 'var(--color-text-muted)' }}>
                            No news items available.
                        </Typography>
                    }

                    {/* Each item is a stop on a timeline, drawn by the news tokens: a rail down the
                        left with a dot beside each item. */}
                    <Box
                        sx={{
                            display: 'flex',
                            flexDirection: 'column',
                            gap: 'var(--news-list-gap)',
                        }}
                        >
                        {!loading && orderedItems.map((item, itemIndex) => (
                            <Box
                                component="article"
                                key={item.id}
                                sx={{
                                    position: 'relative',
                                    display: 'flex',
                                    flexDirection: 'column',
                                    alignItems: 'flex-start',
                                    gap: 'var(--space-2)',
                                    padding: 'var(--news-item-padding-y) var(--news-item-padding-x)',
                                    paddingLeft: 'var(--news-item-indent)',
                                    background: 'var(--news-item-bg)',
                                    borderStyle: 'solid',
                                    borderWidth: '1px',
                                    borderColor: 'var(--news-item-border-color) var(--news-item-border-color) var(--news-divider-color)',
                                    borderRadius: 'var(--news-item-radius)',
                                    boxShadow: 'var(--news-item-shadow)',
                                }}
                                >
                                <Box
                                    aria-hidden={true}
                                    sx={{
                                        display: 'var(--news-rail-display)',
                                        position: 'absolute',
                                        top: itemIndex === 0 ? 'calc(var(--news-item-padding-y) + var(--space-1) + var(--space-1) / 2)' : 0,
                                        bottom: 0,
                                        left: 'calc(var(--space-2) - var(--space-1) / 4)',
                                        width: 'calc(var(--space-1) / 2)',
                                        background: 'var(--color-border)',
                                    }}
                                    />
                                <Box
                                    aria-hidden={true}
                                    sx={{
                                        display: 'var(--news-rail-display)',
                                        position: 'absolute',
                                        top: 'calc(var(--news-item-padding-y) + var(--space-1) + var(--space-1) / 2)',
                                        left: 'calc(var(--space-1) / 2)',
                                        width: 'var(--space-3)',
                                        height: 'var(--space-3)',
                                        borderRadius: 'var(--radius-full)',
                                        background: 'var(--color-bg)',
                                        border: 'calc(var(--space-1) / 2) solid var(--color-border-control)',
                                    }}
                                    />
                                <Typography variant="body1">{item.message}</Typography>
                                {item.link
                                    && <Link
                                        href={item.link.url}
                                        target="_blank"
                                        rel="noopener noreferrer"
                                        underline="hover"
                                        sx={{
                                            display: 'inline-flex',
                                            alignItems: 'center',
                                            gap: 'var(--space-1)',
                                            minHeight: 'var(--button-height-lg)',
                                            color: 'var(--color-accent)',
                                            textDecorationColor: 'currentColor',
                                        }}
                                        >
                                        {item.link.label}
                                        <OpenInNew sx={{ fontSize: 'var(--icon-sm)' }} />
                                    </Link>
                                }
                                {item.action
                                    && <Button
                                        component="a"
                                        href={item.action.url}
                                        target="_blank"
                                        rel="noopener noreferrer"
                                        variant="contained"
                                        size={isMobile ? 'large' : 'medium'}
                                        fullWidth={isMobile}
                                        >
                                        {item.action.label}
                                    </Button>
                                }
                            </Box>
                        ))}
                    </Box>
                </Box>
            </Box>
        </Box>
    );
}
