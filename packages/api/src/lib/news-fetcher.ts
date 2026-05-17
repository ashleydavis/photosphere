import { readFile } from "fs/promises";
import { fileURLToPath } from "url";
import yaml from "js-yaml";

//
// A labelled URL used as either an inline link or CTA action in a news item.
//
export interface INewsLink {
    //
    // Visible label shown to the user.
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
export interface INewsItem {
    //
    // Stable identifier used to track whether this item has already been shown.
    //
    id: string;

    //
    // Message body displayed in the toast.
    //
    message: string;

    //
    // Optional color variant for the toast. Defaults to 'primary' when omitted.
    //
    color?: 'primary' | 'success' | 'warning' | 'danger' | 'neutral';

    //
    // Optional auto-dismiss duration in milliseconds. 0 (or omitted) means no auto-dismiss.
    //
    duration?: number;

    //
    // Optional inline link rendered below the toast message.
    //
    link?: INewsLink;

    //
    // Optional CTA button rendered alongside the toast message.
    //
    action?: INewsLink;
}

//
// On-disk shape of news.yaml.
//
export interface INewsFeed {
    //
    // News items, ordered oldest-first.
    //
    items: INewsItem[];
}

//
// Fetches the news feed at the given URL and returns its items.
// Supports file:// URLs (used by smoke tests) and http(s):// URLs (production).
// Throws on HTTP errors, malformed YAML, or invalid item shapes.
//
export async function fetchNews(url: string): Promise<INewsItem[]> {
    let body: string;
    if (url.startsWith("file://")) {
        const filePath = fileURLToPath(url);
        body = await readFile(filePath, "utf8");
    }
    else {
        const response = await fetch(url);
        if (!response.ok) {
            throw new Error(`Failed to fetch news feed: HTTP ${response.status}`);
        }
        body = await response.text();
    }

    const parsed = yaml.load(body) as INewsFeed | null | undefined;
    if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.items)) {
        throw new Error("Invalid news feed: missing items array");
    }

    for (const item of parsed.items) {
        if (!item || typeof item.id !== "string" || item.id.length === 0) {
            throw new Error("Invalid news item: missing id");
        }
        if (typeof item.message !== "string" || item.message.length === 0) {
            throw new Error("Invalid news item: missing message");
        }
    }

    return parsed.items;
}
