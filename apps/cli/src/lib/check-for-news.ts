import { fetchNews, getShownNewsIds, addShownNewsIds, type INewsItem } from "api";

//
// URL of the news feed published in the Photosphere GitHub repo. Overridable via
// PHOTOSPHERE_NEWS_URL for the local demo scripts (apps/cli/demo-news.sh and
// apps/desktop/demo-news.sh) so they can point at a checked-in test/demo-news.yaml.
//
const NEWS_URL = process.env.PHOTOSPHERE_NEWS_URL || 'https://raw.githubusercontent.com/ashleydavis/photosphere/main/news.yaml';

//
// Fetches the news feed and returns the oldest item that has not yet been shown on this
// install. Marks the returned item as shown so it is not returned again. Returns undefined
// when all items have already been seen, or when the fetch or parse step fails.
//
export async function checkForNews(): Promise<INewsItem | undefined> {
    try {
        const items = await fetchNews(NEWS_URL);
        const shownIds = new Set<string>(await getShownNewsIds());
        let nextItem: INewsItem | undefined = undefined;
        for (const item of items) {
            if (!shownIds.has(item.id)) {
                nextItem = item;
                break;
            }
        }
        if (nextItem === undefined) {
            return undefined;
        }
        await addShownNewsIds([nextItem.id]);
        return nextItem;
    }
    catch (error) {
        return undefined;
    }
}

//
// A news item paired with whether it has already been shown on this install. Returned by
// getAllNews() so callers (like the `psi news` command) can render the full feed and
// indicate which items are new to the user.
//
export interface INewsItemWithState {
    //
    // The news item as published in news.yaml.
    //
    item: INewsItem;

    //
    // True when the item's id is already recorded in shown_news_ids.
    //
    seen: boolean;
}

//
// Fetches the entire news feed (regardless of seen state) and pairs each item with a
// `seen` flag derived from the locally-persisted shown_news_ids list. Returns an
// empty array on fetch or parse failure so callers can render gracefully when offline.
//
export async function getAllNews(): Promise<INewsItemWithState[]> {
    try {
        const items = await fetchNews(NEWS_URL);
        const shownIds = new Set<string>(await getShownNewsIds());
        return items.map(item => ({
            item,
            seen: shownIds.has(item.id),
        }));
    }
    catch (error) {
        return [];
    }
}

//
// Records the supplied news item ids as shown, so they no longer surface via checkForNews()
// in subsequent CLI invocations. Used by `psi news` after rendering the full feed.
//
export async function markNewsAsShown(ids: string[]): Promise<void> {
    if (ids.length === 0) {
        return;
    }
    try {
        await addShownNewsIds(ids);
    }
    catch (error) {
        // News persistence failures must never block the user.
    }
}
