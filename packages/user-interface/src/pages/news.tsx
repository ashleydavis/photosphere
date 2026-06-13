import React, { useEffect, useState } from "react";
import { version } from "config";
import { useApi } from "../context/api-context";

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
        <div className="w-full h-full p-4 overflow-y-auto pb-32">
            <div className="m-auto" style={{ maxWidth: "800px" }}>
                <h1 className="mt-6 text-3xl">News</h1>

                <section className="pt-6">
                    <h2 className="text-xl">Version</h2>
                    <p className="pt-2">
                        <span className="font-semibold">Running version:</span> v{runningVersion}
                    </p>
                    {latestVersion !== undefined && (
                        <p className="pt-1">
                            <span className="font-semibold">Latest release:</span> v{latestVersion}
                            {hasUpdate
                                ? <span className="ml-2 text-green-600 font-semibold">(update available)</span>
                                : <span className="ml-2 text-gray-500">(up to date)</span>
                            }
                        </p>
                    )}
                    {hasUpdate && (
                        <p className="pt-2">
                            <a
                                target="_blank"
                                rel="noopener noreferrer"
                                href="https://github.com/ashleydavis/photosphere/releases/latest"
                                className="text-blue-600 underline"
                                >
                                Download the latest release
                            </a>
                        </p>
                    )}
                </section>

                <section className="pt-8">
                    <h2 className="text-xl">News items</h2>
                    {loading
                        ? <p className="pt-2 text-gray-500">Loading...</p>
                        : orderedItems.length === 0
                            ? <p className="pt-2 text-gray-500">No news items available.</p>
                            : (
                                <ul className="pt-2 space-y-4">
                                    {orderedItems.map(item => (
                                        <li key={item.id} className="border-l-4 border-gray-300 pl-3">
                                            <p>{item.message}</p>
                                            {item.link && (
                                                <p className="pt-1">
                                                    <a
                                                        target="_blank"
                                                        rel="noopener noreferrer"
                                                        href={item.link.url}
                                                        className="text-blue-600 underline"
                                                        >
                                                        {item.link.label}
                                                    </a>
                                                </p>
                                            )}
                                            {item.action && (
                                                <p className="pt-1">
                                                    <a
                                                        target="_blank"
                                                        rel="noopener noreferrer"
                                                        href={item.action.url}
                                                        className="text-blue-600 underline"
                                                        >
                                                        {item.action.label}
                                                    </a>
                                                </p>
                                            )}
                                        </li>
                                    ))}
                                </ul>
                            )
                    }
                </section>
            </div>
        </div>
    );
}
