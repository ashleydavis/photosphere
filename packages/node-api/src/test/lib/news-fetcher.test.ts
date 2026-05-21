import * as os from "os";
import * as path from "path";
import { writeFile, mkdtemp, rm } from "fs/promises";
import { pathToFileURL } from "url";
import { fetchNews } from "../../lib/news-fetcher";

//
// Builds a Response-like object compatible with the fetch return type used in the source.
//
function makeResponse(body: string, ok: boolean, status: number): Response {
    const fakeResponse: any = {
        ok,
        status,
        text: () => Promise.resolve(body),
    };
    return fakeResponse as Response;
}

describe('fetchNews', () => {
    let originalFetch: typeof globalThis.fetch;

    beforeEach(() => {
        originalFetch = globalThis.fetch;
    });

    afterEach(() => {
        globalThis.fetch = originalFetch;
    });

    test('returns parsed items when the YAML is valid', async () => {
        const yamlBody = `items:
  - id: a
    message: Hello
  - id: b
    message: World
    color: warning
    duration: 5000
`;
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse(yamlBody, true, 200)) as any;

        const items = await fetchNews('https://example.com/news.yaml');

        expect(items).toHaveLength(2);
        expect(items[0]).toEqual({ id: 'a', message: 'Hello' });
        expect(items[1]).toEqual({ id: 'b', message: 'World', color: 'warning', duration: 5000 });
    });

    test('throws when the YAML is malformed', async () => {
        const yamlBody = '::: not yaml :::\n  bad\n - indent';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse(yamlBody, true, 200)) as any;

        await expect(fetchNews('https://example.com/news.yaml')).rejects.toThrow();
    });

    test('throws when items is missing', async () => {
        const yamlBody = `other: stuff\n`;
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse(yamlBody, true, 200)) as any;

        await expect(fetchNews('https://example.com/news.yaml')).rejects.toThrow('Invalid news feed: missing items array');
    });

    test('throws when an item is missing id', async () => {
        const yamlBody = `items:
  - message: Hello
`;
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse(yamlBody, true, 200)) as any;

        await expect(fetchNews('https://example.com/news.yaml')).rejects.toThrow('Invalid news item: missing id');
    });

    test('throws when an item is missing message', async () => {
        const yamlBody = `items:
  - id: a
`;
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse(yamlBody, true, 200)) as any;

        await expect(fetchNews('https://example.com/news.yaml')).rejects.toThrow('Invalid news item: missing message');
    });

    test('returns an empty array when items is empty', async () => {
        const yamlBody = `items: []\n`;
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse(yamlBody, true, 200)) as any;

        const items = await fetchNews('https://example.com/news.yaml');

        expect(items).toEqual([]);
    });

    test('throws when the HTTP response is not ok', async () => {
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse('', false, 500)) as any;

        await expect(fetchNews('https://example.com/news.yaml')).rejects.toThrow('Failed to fetch news feed: HTTP 500');
    });

    test('reads from disk for file:// URLs', async () => {
        const tmpDir = await mkdtemp(path.join(os.tmpdir(), 'news-fetcher-test-'));
        const filePath = path.join(tmpDir, 'news.yaml');
        const yamlBody = `items:
  - id: a
    message: From file
    link:
      label: Open
      url: https://example.com/open
    action:
      label: Go
      url: https://example.com/go
`;
        await writeFile(filePath, yamlBody, 'utf8');

        try {
            const url = pathToFileURL(filePath).toString();
            const items = await fetchNews(url);
            expect(items).toEqual([{
                id: 'a',
                message: 'From file',
                link: { label: 'Open', url: 'https://example.com/open' },
                action: { label: 'Go', url: 'https://example.com/go' },
            }]);
        }
        finally {
            await rm(tmpDir, { recursive: true, force: true });
        }
    });
});
