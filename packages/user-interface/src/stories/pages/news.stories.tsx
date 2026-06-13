import React from "react";
import { NewsPage } from "../../pages/news";
import { MockProviders } from "../mocks";
import type { IApi } from "../../context/api-context";
import type { IStory } from "../types";

//
// A published news feed (in news.yaml format) with a few sample items, used by
// the "with items" story version.
//
const NEWS_FEED_WITH_ITEMS = `items:
  - id: welcome
    message: "Welcome to Photosphere. Thanks for trying it out!"
  - id: new-release
    message: "A new release is available with bug fixes and performance improvements."
    action:
      label: "Download the latest release"
      url: "https://github.com/ashleydavis/photosphere/releases/latest"
  - id: docs
    message: "Check out the documentation to learn more."
    link:
      label: "Read the docs"
      url: "https://github.com/ashleydavis/photosphere"
`;

//
// An empty news feed, used by the "no items" story version.
//
const NEWS_FEED_EMPTY = `items:
`;

//
// Builds a mock API client that serves the GitHub release info and the supplied
// news feed, so the News page can be rendered with controlled data.
//
function mockNewsApi(newsFeed: string): IApi {
    return {
        async get(url: string) {
            if (url.includes("releases/latest")) {
                return { data: { tag_name: "v9.9.9" }, status: 200 };
            }
            return { data: newsFeed, status: 200 };
        },
        async post() {
            return { data: "", status: 200 };
        },
    } as IApi;
}

//
// Stories for the News page.
//
export const stories: IStory[] = [
    {
        id: "news-page/with-items",
        name: "News (with items)",
        category: "Pages",
        render: () => (
            <MockProviders api={mockNewsApi(NEWS_FEED_WITH_ITEMS)}>
                <NewsPage />
            </MockProviders>
        ),
    },
    {
        id: "news-page/no-items",
        name: "News (no items)",
        category: "Pages",
        render: () => (
            <MockProviders api={mockNewsApi(NEWS_FEED_EMPTY)}>
                <NewsPage />
            </MockProviders>
        ),
    },
];
