const mockVersion = { value: 'dev' };
jest.mock('config', () => ({
    get version() { return mockVersion.value; },
    buildMetadata: { commitHash: 'dev', buildDate: 'development', isNightly: false },
}));

const mockGetLastShownUpdateVersion = jest.fn();
const mockSetLastShownUpdateVersion = jest.fn();
jest.mock('api', () => ({
    getLastShownUpdateVersion: mockGetLastShownUpdateVersion,
    setLastShownUpdateVersion: mockSetLastShownUpdateVersion,
}));

import { checkForUpdates, markUpdateAsShown, getLatestVersion } from '../../lib/check-for-updates';

//
// Builds a minimal Response-compatible object for the mocked fetch.
//
function makeResponse(body: any, ok: boolean, status: number): Response {
    const fakeResponse: any = {
        ok,
        status,
        json: () => Promise.resolve(body),
    };
    return fakeResponse as Response;
}

describe('checkForUpdates', () => {
    let originalFetch: typeof globalThis.fetch;

    beforeEach(() => {
        originalFetch = globalThis.fetch;
        jest.clearAllMocks();
        // Default: no version has been shown yet so checkForUpdates returns whatever GitHub reports.
        mockGetLastShownUpdateVersion.mockResolvedValue(undefined);
    });

    afterEach(() => {
        globalThis.fetch = originalFetch;
        mockVersion.value = 'dev';
    });

    test('returns undefined for dev builds', async () => {
        mockVersion.value = 'dev';
        const fetchSpy = jest.fn();
        globalThis.fetch = fetchSpy as any;

        const result = await checkForUpdates();

        expect(result).toBeUndefined();
        expect(fetchSpy).not.toHaveBeenCalled();
    });

    test('returns undefined for nightly builds', async () => {
        mockVersion.value = '1.2.3-nightly';
        const fetchSpy = jest.fn();
        globalThis.fetch = fetchSpy as any;

        const result = await checkForUpdates();

        expect(result).toBeUndefined();
        expect(fetchSpy).not.toHaveBeenCalled();
    });

    test('returns the latest version when newer than the current version', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: 'v1.3.0' }, true, 200)) as any;

        const result = await checkForUpdates();

        expect(result).toBe('1.3.0');
    });

    test('returns undefined when the latest version matches the current version', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: 'v1.2.3' }, true, 200)) as any;

        const result = await checkForUpdates();

        expect(result).toBeUndefined();
    });

    test('handles tag without v prefix', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: '1.4.0' }, true, 200)) as any;

        const result = await checkForUpdates();

        expect(result).toBe('1.4.0');
    });

    test('returns undefined when fetch fails', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockRejectedValue(new Error('network')) as any;

        const result = await checkForUpdates();

        expect(result).toBeUndefined();
    });

    test('returns undefined when response is not ok', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({}, false, 500)) as any;

        const result = await checkForUpdates();

        expect(result).toBeUndefined();
    });

    test('returns undefined when tag_name is missing', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({}, true, 200)) as any;

        const result = await checkForUpdates();

        expect(result).toBeUndefined();
    });

    test('suppresses notification when the latest version has already been recorded', async () => {
        mockVersion.value = '1.2.3';
        mockGetLastShownUpdateVersion.mockResolvedValue('1.3.0');
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: 'v1.3.0' }, true, 200)) as any;

        const result = await checkForUpdates();

        expect(result).toBeUndefined();
    });

    test('returns the latest version when last-shown is an older version', async () => {
        mockVersion.value = '1.2.3';
        mockGetLastShownUpdateVersion.mockResolvedValue('1.2.5');
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: 'v1.3.0' }, true, 200)) as any;

        const result = await checkForUpdates();

        expect(result).toBe('1.3.0');
    });
});

describe('markUpdateAsShown', () => {
    beforeEach(() => jest.clearAllMocks());

    test('persists the supplied version', async () => {
        await markUpdateAsShown('1.3.0');

        expect(mockSetLastShownUpdateVersion).toHaveBeenCalledWith('1.3.0');
    });

    test('swallows persistence errors', async () => {
        mockSetLastShownUpdateVersion.mockRejectedValue(new Error('disk full'));

        await expect(markUpdateAsShown('1.3.0')).resolves.toBeUndefined();
    });
});

describe('getLatestVersion', () => {
    let originalFetch: typeof globalThis.fetch;

    beforeEach(() => {
        originalFetch = globalThis.fetch;
        jest.clearAllMocks();
    });

    afterEach(() => {
        globalThis.fetch = originalFetch;
        mockVersion.value = 'dev';
    });

    test('returns undefined for dev builds without calling fetch', async () => {
        mockVersion.value = 'dev';
        const fetchSpy = jest.fn();
        globalThis.fetch = fetchSpy as any;

        const result = await getLatestVersion();

        expect(result).toBeUndefined();
        expect(fetchSpy).not.toHaveBeenCalled();
    });

    test('returns undefined for nightly builds without calling fetch', async () => {
        mockVersion.value = '1.2.3-nightly';
        const fetchSpy = jest.fn();
        globalThis.fetch = fetchSpy as any;

        const result = await getLatestVersion();

        expect(result).toBeUndefined();
        expect(fetchSpy).not.toHaveBeenCalled();
    });

    test('returns the latest version reported by GitHub', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: 'v1.3.0' }, true, 200)) as any;

        const result = await getLatestVersion();

        expect(result).toBe('1.3.0');
    });

    test('returns the latest version even when it matches the running version', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: 'v1.2.3' }, true, 200)) as any;

        const result = await getLatestVersion();

        expect(result).toBe('1.2.3');
    });

    test('strips a leading v from the tag', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: 'v1.4.0' }, true, 200)) as any;

        const result = await getLatestVersion();

        expect(result).toBe('1.4.0');
    });

    test('handles a tag without a leading v', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: '1.4.0' }, true, 200)) as any;

        const result = await getLatestVersion();

        expect(result).toBe('1.4.0');
    });

    test('does NOT consult last_shown_update_version', async () => {
        mockVersion.value = '1.2.3';
        mockGetLastShownUpdateVersion.mockResolvedValue('1.3.0');
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: 'v1.3.0' }, true, 200)) as any;

        const result = await getLatestVersion();

        expect(result).toBe('1.3.0');
        expect(mockGetLastShownUpdateVersion).not.toHaveBeenCalled();
    });

    test('returns undefined when the fetch fails', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockRejectedValue(new Error('network')) as any;

        const result = await getLatestVersion();

        expect(result).toBeUndefined();
    });

    test('returns undefined when the response is not ok', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({}, false, 500)) as any;

        const result = await getLatestVersion();

        expect(result).toBeUndefined();
    });

    test('returns undefined when the response has no tag_name', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({}, true, 200)) as any;

        const result = await getLatestVersion();

        expect(result).toBeUndefined();
    });

    test('does not write to last_shown_update_version', async () => {
        mockVersion.value = '1.2.3';
        globalThis.fetch = jest.fn().mockResolvedValue(makeResponse({ tag_name: 'v1.3.0' }, true, 200)) as any;

        await getLatestVersion();

        expect(mockSetLastShownUpdateVersion).not.toHaveBeenCalled();
    });
});
