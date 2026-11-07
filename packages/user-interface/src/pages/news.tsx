import React, { useEffect, useState } from "react";
import { version } from "config";
import Box from "@mui/joy/Box";
import Card from "@mui/joy/Card";
import Chip from "@mui/joy/Chip";
import Button from "@mui/joy/Button";
import Typography from "@mui/joy/Typography";
import Link from "@mui/joy/Link";
import CircularProgress from "@mui/joy/CircularProgress";
import { Download, OpenInNew } from "@mui/icons-material";
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
        <Box sx={{ width: '100%', height: '100%', overflowY: 'auto', p: isMobile ? 2 : 4, pb: 16 }}>
            <Box sx={{ mx: 'auto', maxWidth: 800 }}>
                <Typography level="h2" sx={{ fontSize: isMobile ? '1.75rem' : '2rem', mb: 2 }}>
                    News
                </Typography>

                {/* The version card leads with whether there is an update, because that is the one
                    thing anybody opens this page to find out. The download is a full-width button
                    on a phone rather than an underlined link. */}
                <Card
                    variant={hasUpdate ? 'soft' : 'outlined'}
                    color={hasUpdate ? 'success' : 'neutral'}
                    sx={{ borderRadius: 'lg', p: 2, gap: 1 }}
                    >
                    <Box sx={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 1 }}>
                        <Typography level="title-md">{`Version v${runningVersion}`}</Typography>
                        {latestVersion !== undefined
                            && <Chip
                                size="sm"
                                variant="solid"
                                color={hasUpdate ? 'success' : 'neutral'}
                                >
                                {hasUpdate ? 'Update available' : 'Up to date'}
                            </Chip>
                        }
                    </Box>

                    {latestVersion !== undefined
                        && <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                            {`Latest release: v${latestVersion}`}
                        </Typography>
                    }

                    {hasUpdate
                        && <Button
                            component="a"
                            href="https://github.com/ashleydavis/photosphere/releases/latest"
                            target="_blank"
                            rel="noopener noreferrer"
                            size="lg"
                            color="success"
                            startDecorator={<Download />}
                            sx={{ minHeight: 48, mt: 0.5 }}
                            >
                            Download the latest release
                        </Button>
                    }
                </Card>

                <Typography level="title-lg" sx={{ mt: 3, mb: 1.5 }}>News items</Typography>

                {loading
                    && <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, py: 2 }}>
                        <CircularProgress size="sm" />
                        <Typography level="body-md" sx={{ color: 'text.tertiary' }}>Loading...</Typography>
                    </Box>
                }

                {!loading && orderedItems.length === 0
                    && <Typography level="body-md" sx={{ color: 'text.tertiary' }}>
                        No news items available.
                    </Typography>
                }

                {!loading && orderedItems.map(item => (
                    <Card
                        key={item.id}
                        variant="soft"
                        sx={{ borderRadius: 'lg', p: 2, mb: 1.5, gap: 1 }}
                        >
                        <Typography level="body-md">{item.message}</Typography>
                        {item.link
                            && <Link
                                href={item.link.url}
                                target="_blank"
                                rel="noopener noreferrer"
                                endDecorator={<OpenInNew fontSize="small" />}
                                sx={{ minHeight: 44, alignItems: 'center' }}
                                >
                                {item.link.label}
                            </Link>
                        }
                        {item.action
                            && <Button
                                component="a"
                                href={item.action.url}
                                target="_blank"
                                rel="noopener noreferrer"
                                variant="solid"
                                size={isMobile ? 'lg' : 'md'}
                                sx={{ minHeight: isMobile ? 48 : undefined, alignSelf: isMobile ? 'stretch' : 'flex-start' }}
                                >
                                {item.action.label}
                            </Button>
                        }
                    </Card>
                ))}
            </Box>
        </Box>
    );
}
