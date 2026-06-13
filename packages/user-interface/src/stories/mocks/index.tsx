import React, { ReactNode, useEffect, useState } from "react";
import { CssVarsProvider } from "@mui/joy/styles/CssVarsProvider";
import { RandomUuidGenerator, type IUuidGenerator } from "utils";
import { getQueueBackend } from "task-queue";
import { UuidGeneratorProvider } from "../../context/uuid-generator-context";
import {
    PlatformContextProvider,
    type IPlatformContext,
    type Unsubscribe,
    type IDatabaseEntry,
    type ISharedSecretEntry,
    type IToolsStatus,
} from "../../context/platform-context";
import { AppContextProvider } from "../../context/app-context";
import { ApiContextProvider, axiosApi, type IApi } from "../../context/api-context";
import { ToastContextProvider } from "../../context/toast-context";
import { ConfigContextProvider, createConfig } from "../../context/config-context";
import {
    AssetDatabaseContext,
    AssetDatabaseProvider,
    useAssetDatabase,
    type IAssetDatabase,
} from "../../context/asset-database-source";
import { GallerySourceContext } from "../../context/gallery-source";
import type { IGalleryItem } from "../../lib/gallery-item";
import { Observable } from "../../lib/subscription";
import { ImportContext, ImportContextProvider, type IImportContext, type IImportItem } from "../../context/import-context";
import { GalleryContextProvider } from "../../context/gallery-context";
import { DeleteConfirmationContextProvider } from "../../context/delete-confirmation-context";
import { SearchContextProvider } from "../../context/search-context";
import { GalleryLayoutContextProvider } from "../../context/gallery-layout-context";
import type { IAsset } from "api";

//
// A no-op synchronous callback. Use for event handler props in stories
// where the action does not need to do anything.
//
export const noOp: () => void = () => {};

//
// A no-op async callback. Use for Promise-returning event handler props
// in stories where the action does not need to do anything.
//
export const noOpAsync: () => Promise<void> = async () => {};

//
// Builds a deterministic uuid generator that returns "mock-uuid-<n>" values.
//
function mockUuidGenerator(): IUuidGenerator {
    let counter = 0;
    return {
        generate: () => {
            counter += 1;
            return `mock-uuid-${counter}`;
        },
    };
}

//
// Returns a fake platform implementation whose every method is a no-op or
// returns a resolved promise. Subscriber methods return an unsubscribe
// function that does nothing.
//
export function mockPlatform(): IPlatformContext {
    const noUnsubscribe: Unsubscribe = () => {};
    const emptyToolsStatus: IToolsStatus = {
        magick: { available: true },
        ffprobe: { available: true },
        ffmpeg: { available: true },
        allAvailable: true,
        missingTools: [],
    };

    return {
        openDatabase: async () => {},
        onDatabaseOpened: () => noUnsubscribe,
        onDatabaseClosed: () => noUnsubscribe,
        notifyDatabaseOpened: async () => {},
        notifyDatabaseClosed: async () => {},
        onThemeChanged: () => noUnsubscribe,
        onMenuAction: () => noUnsubscribe,
        onNavigate: () => noUnsubscribe,
        notifyDatabaseEdited: () => {},
        copyToClipboard: async () => {},
        onSyncStarted: () => noUnsubscribe,
        onSyncCompleted: () => noUnsubscribe,
        onShowNotification: () => noUnsubscribe,
        onDatabasesChanged: () => noUnsubscribe,
        onUpdateAvailable: () => noUnsubscribe,
        openFolder: async () => {},
        getPathForFile: () => undefined,
        checkTools: async () => emptyToolsStatus,
        checkDatabaseExists: async () => true,
        onTaskMessage: () => noUnsubscribe,
        onTaskComplete: () => noUnsubscribe,
        cancelTasks: async () => {},
        getDatabases: async () => [],
        addDatabase: async (entry: IDatabaseEntry) => entry,
        updateDatabase: async () => {},
        setDatabaseOrigin: async () => {},
        removeDatabaseEntry: async () => {},
        findDatabase: async () => undefined,
        pickFolder: async () => undefined,
        pickFile: async () => undefined,
        pickFiles: async () => undefined,
        listSecrets: async () => [],
        addSecret: async (entry: ISharedSecretEntry) => entry,
        updateSecret: async () => {},
        deleteSecret: async () => {},
        getSecretValue: async () => undefined,
        getRecentDatabases: async () => [],
        removeRecentDatabaseName: async () => {},
        listS3Dirs: async () => [],
        startShareReceive: async () => {},
        waitShareReceive: async () => null,
        cancelShareReceive: async () => {},
        waitForReceiver: async () => null,
        sendToReceiver: async () => true,
        cancelShareSend: async () => {},
        importSharePayload: async () => {},
        markUpdateAsShown: async () => {},
        markNewsAsShown: async () => {},
    };
}

//
// Returns a fake API client whose requests resolve to empty responses. Stories
// that need specific HTTP behaviour pass their own IApi to MockProviders.
//
export function mockApi(): IApi {
    return {
        async get() {
            return { data: "", status: 200 };
        },
        async post() {
            return { data: "", status: 200 };
        },
    } as IApi;
}

//
// Returns a fake gallery item with sensible defaults. Pass overrides to
// customise specific fields.
//
export function mockGalleryItem(overrides?: Partial<IGalleryItem>): IGalleryItem {
    const base: IGalleryItem = {
        _id: "mock-asset-1",
        origFileName: "mock.jpg",
        contentType: "image/jpeg",
        width: 800,
        height: 600,
        hash: "mock-hash",
        fileDate: "2024-01-01T00:00:00.000Z",
        uploadDate: "2024-01-01T00:00:00.000Z",
        photoDate: "2024-01-01T00:00:00.000Z",
        micro: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
        color: [128, 128, 128],
    };
    return { ...base, ...overrides };
}

//
// Returns a fake IAsset record with sensible defaults. Pass overrides to
// customise specific fields.
//
export function mockAsset(overrides?: Partial<IAsset>): IAsset {
    const base: IAsset = {
        _id: "mock-asset-1",
        origFileName: "mock.jpg",
        contentType: "image/jpeg",
        width: 800,
        height: 600,
        hash: "mock-hash",
        fileDate: "2024-01-01T00:00:00.000Z",
        uploadDate: "2024-01-01T00:00:00.000Z",
        photoDate: "2024-01-01T00:00:00.000Z",
        micro: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
        color: [128, 128, 128],
    };
    return { ...base, ...overrides };
}

//
// Returns an array of `count` fake gallery items with deterministic ids
// of the form `mock-asset-<n>`.
//
export function mockAssets(count: number): IGalleryItem[] {
    const items: IGalleryItem[] = [];
    for (let index = 0; index < count; index++) {
        items.push(mockGalleryItem({
            _id: `mock-asset-${index + 1}`,
            origFileName: `mock-${index + 1}.jpg`,
        }));
    }
    return items;
}

//
// Returns a fake IAssetDatabase implementation backed by an in-memory map
// of assets. All methods are no-ops or return resolved promises.
//
export function mockAssetDatabase(assets?: IGalleryItem[]): IAssetDatabase {
    const assetMap: { [assetId: string]: IGalleryItem } = {};
    if (assets) {
        for (const item of assets) {
            assetMap[item._id] = item;
        }
    }

    //
    // Deliver the assets to the gallery context the same way the real asset
    // database delivers items loaded from disk. Observable buffers payloads
    // invoked before the first subscription, so the items arrive when the
    // gallery context subscribes on mount.
    //
    const onNewItems = new Observable<IGalleryItem[]>();
    if (assets && assets.length > 0) {
        onNewItems.invoke(assets);
    }

    return {
        isLoading: false,
        isSyncing: false,
        isWorking: false,
        isReadOnly: false,
        getAssets: () => assetMap,
        onReset: new Observable<void>(),
        onNewItems,
        onItemsUpdated: new Observable<{ assetIds: string[] }>(),
        onItemsDeleted: new Observable<{ assetIds: string[] }>(),
        updateAsset: async () => {},
        updateAssets: async () => {},
        addArrayValue: async () => {},
        removeArrayValue: async () => {},
        deleteAssets: async () => {},
        loadAsset: async () => undefined,
        getItemById: (assetId: string) => assetMap[assetId],
        assetUrl: (assetId, assetType) => `mock://${assetType}/${assetId}`,
        databasePath: "/mock/database",
        setDatabasePath: () => {},
        closeDatabase: async () => {},
        moveToDatabase: async () => {},
        selectAndOpenDatabase: async () => {},
        createDatabase: async () => {},
        createDatabaseAtPath: async () => {},
        openDatabase: async () => {},
        downloadAsset: async () => {},
        downloadAssets: async () => {},
    };
}

//
// A base64-encoded JPEG micro-thumbnail used for mock import items so the
// "in progress" story renders real thumbnails next to imported files.
//
const mockMicroThumbnail = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

//
// Returns a fake import context value with sensible defaults. Pass overrides
// to set a particular status or item list for stories that need to show an
// import in a specific state. All action methods are no-ops.
//
export function mockImportContext(overrides?: Partial<IImportContext>): IImportContext {
    const base: IImportContext = {
        status: 'idle',
        importItems: [],
        startImportDirectories: async () => false,
        startImportFiles: async () => false,
        cancelImport: noOpAsync,
        clearImport: noOp,
    };
    return { ...base, ...overrides };
}

//
// Returns a list of mock import items representing an import in progress:
// some files already succeeded (with thumbnails) and some are still pending.
//
export function mockInProgressImportItems(): IImportItem[] {
    return [
        { assetId: "mock-import-1", logicalPath: "photos/holiday/img001.jpg", status: 'success', micro: mockMicroThumbnail },
        { assetId: "mock-import-2", logicalPath: "photos/holiday/img002.jpg", status: 'success', micro: mockMicroThumbnail },
        { assetId: "mock-import-3", logicalPath: "photos/holiday/img003.jpg", status: 'skipped' },
        { assetId: "mock-import-4", logicalPath: "photos/holiday/img004.jpg", status: 'pending' },
        { assetId: "mock-import-5", logicalPath: "photos/holiday/img005.jpg", status: 'pending' },
    ];
}

//
// Props consumed by MockProviders. Each override lets a story replace
// the default mock instance for a particular context.
//
export interface IMockProvidersProps {
    //
    // Story content to wrap in the provider stack.
    //
    children: ReactNode | ReactNode[];

    //
    // Optional override for the uuid generator. Defaults to a deterministic
    // mock generator that returns "mock-uuid-<n>" values.
    //
    uuidGenerator?: IUuidGenerator;

    //
    // Optional override for the platform context. Defaults to the no-op
    // mock returned by mockPlatform().
    //
    platform?: IPlatformContext;

    //
    // Optional override for the API/HTTP client. Defaults to the empty-response
    // mock returned by mockApi(). Pass a custom IApi to control HTTP responses
    // (e.g. the news feed) for a story.
    //
    api?: IApi;

    //
    // Optional override for the asset database context. Defaults to an
    // in-memory mock with no assets loaded.
    //
    assetDatabase?: IAssetDatabase;

    //
    // Optional override for the import context. When provided, the real
    // ImportContextProvider is bypassed and this value is supplied directly,
    // letting a story render the import page in a specific state.
    //
    importContext?: IImportContext;
}

//
// Wraps story content in mock instances of every context provider exported
// by user-interface. Stories that need to vary behaviour can pass override
// props for individual contexts.
//
// Does NOT include a Router: stories are mounted inside the consuming app's
// HashRouter (via the /stories route), so adding one here would trigger
// React Router's "cannot render a <Router> inside another <Router>" error.
//
//
// Builds an in-memory IConfig backed by a plain object, so components that
// consume useConfig() get a working implementation in stories.
//
function createInMemoryConfig() {
    const configStore: { [key: string]: unknown } = {};
    return createConfig(
        async (key: string) => configStore[key],
        async (key: string, value: unknown) => { configStore[key] = value; },
    );
}

export function MockProviders({
    children,
    uuidGenerator,
    platform,
    api,
    assetDatabase,
    importContext,
}: IMockProvidersProps) {
    const platformValue = platform || mockPlatform();
    const apiValue = api || mockApi();
    const uuidGeneratorValue = uuidGenerator || mockUuidGenerator();
    const databaseValue = assetDatabase || mockAssetDatabase();

    //
    // In-memory config so any story that consumes useConfig() gets a real
    // implementation instead of crashing on missing context.
    //
    const config = createInMemoryConfig();

    //
    // When a story supplies an import context, provide it directly so the
    // import page can be rendered in a fixed state; otherwise use the real
    // provider which manages live import state.
    //
    function withImportContext(content: ReactNode): JSX.Element {
        if (importContext) {
            return (
                <ImportContext.Provider value={importContext}>
                    {content}
                </ImportContext.Provider>
            );
        }
        return (
            <ImportContextProvider>
                {content}
            </ImportContextProvider>
        );
    }

    return (
        <CssVarsProvider>
            <UuidGeneratorProvider value={uuidGeneratorValue}>
                <PlatformContextProvider value={platformValue}>
                    <ApiContextProvider value={apiValue}>
                    <ConfigContextProvider value={config}>
                        <AppContextProvider>
                            <ToastContextProvider>
                                <AssetDatabaseContext.Provider value={databaseValue}>
                                    <GallerySourceContext.Provider value={databaseValue}>
                                        {withImportContext(
                                            <GalleryContextProvider>
                                                <DeleteConfirmationContextProvider>
                                                    <SearchContextProvider>
                                                        <GalleryLayoutContextProvider>
                                                            {children}
                                                        </GalleryLayoutContextProvider>
                                                    </SearchContextProvider>
                                                </DeleteConfirmationContextProvider>
                                            </GalleryContextProvider>
                                        )}
                                    </GallerySourceContext.Provider>
                                </AssetDatabaseContext.Provider>
                            </ToastContextProvider>
                        </AppContextProvider>
                    </ConfigContextProvider>
                    </ApiContextProvider>
                </PlatformContextProvider>
            </UuidGeneratorProvider>
        </CssVarsProvider>
    );
}

//
// Candidate paths for the repo's 50-assets test database, relative to the
// working directory of the process hosting the REST API. The first covers
// `bun run dev` and `bun run dev:web` (the server runs from apps/<app>), the
// second covers app processes launched from the repo root (smoke tests).
//
const testDatabaseCandidates = [
    "../../test/dbs/50-assets",
    "test/dbs/50-assets",
];

//
// Id of a known asset in the 50-assets test database. Used to probe which
// candidate database path the REST API can actually reach.
//
const probeAssetId = "63e9c637-9164-6376-13e9-ef3200000000";

//
// Resolves the REST API base url for stories. The Electron shell passes
// restApiUrl as a query parameter (same as the real app); the dev web
// frontend talks to the fixed dev-server url.
//
function storyRestApiUrl(): string {
    const urlParams = new URLSearchParams(window.location.search);
    return urlParams.get("restApiUrl") || "http://localhost:3001";
}

//
// Props for OpenTestDatabase.
//
interface IOpenTestDatabaseProps {
    //
    // Story content rendered while and after the database loads.
    //
    children: ReactNode | ReactNode[];
}

//
// Probes the REST API for the repo's 50-assets test database and opens the
// first reachable candidate path through the real asset database provider.
// Renders an explanatory message when the database cannot be reached (e.g.
// a packaged app installed outside the repo).
//
function OpenTestDatabase({ children }: IOpenTestDatabaseProps) {
    const { openDatabase } = useAssetDatabase();
    const [probeFailed, setProbeFailed] = useState<boolean>(false);

    useEffect(() => {
        let disposed = false;

        //
        // Finds the first candidate database path the REST API can serve an
        // asset from, then opens it the same way the app opens any database.
        //
        async function locateAndOpenDatabase(): Promise<void> {
            const restApiUrl = storyRestApiUrl();
            for (const candidatePath of testDatabaseCandidates) {
                const probeUrl = `${restApiUrl}/asset?id=${encodeURIComponent(probeAssetId)}&type=thumb&db=${encodeURIComponent(candidatePath)}`;
                try {
                    const response = await fetch(probeUrl);
                    if (response.ok) {
                        if (!disposed) {
                            await openDatabase(candidatePath);
                        }
                        return;
                    }
                }
                catch {
                    // The REST API itself is unreachable; no candidate can work.
                    break;
                }
            }
            if (!disposed) {
                setProbeFailed(true);
            }
        }

        locateAndOpenDatabase();

        return () => {
            disposed = true;
        };
    }, []);

    if (probeFailed) {
        return (
            <div className="p-4">
                Could not reach the 50-assets test database (test/dbs/50-assets) via the REST API.
                This story needs the app to be running from the repository.
            </div>
        );
    }

    return <>{children}</>;
}

//
// Props for RealDatabaseProviders.
//
export interface IRealDatabaseProvidersProps {
    //
    // Story content to wrap in the provider stack.
    //
    children: ReactNode | ReactNode[];
}

//
// Wraps story content in the real provider stack: the real
// AssetDatabaseProvider talking to the app's REST API and task queue, loading
// the repo's 50-assets test database exactly the way the app loads any
// database. Platform and config stay mocked because stories run outside the
// app shell.
//
export function RealDatabaseProviders({ children }: IRealDatabaseProvidersProps) {
    //
    // Created once per mount (lazy state initialisers) so context consumers
    // do not resubscribe on every render.
    //
    const [platformValue] = useState<IPlatformContext>(() => mockPlatform());
    const [uuidGeneratorValue] = useState<IUuidGenerator>(() => new RandomUuidGenerator());
    const [config] = useState(() => createInMemoryConfig());

    return (
        <CssVarsProvider>
            <UuidGeneratorProvider value={uuidGeneratorValue}>
                <PlatformContextProvider value={platformValue}>
                    <ApiContextProvider value={axiosApi}>
                    <ConfigContextProvider value={config}>
                        <AppContextProvider>
                            <ToastContextProvider>
                                <AssetDatabaseProvider queueBackend={getQueueBackend()} restApiUrl={storyRestApiUrl()}>
                                    <ImportContextProvider>
                                        <GalleryContextProvider>
                                            <DeleteConfirmationContextProvider>
                                                <SearchContextProvider>
                                                    <GalleryLayoutContextProvider>
                                                        <OpenTestDatabase>
                                                            {children}
                                                        </OpenTestDatabase>
                                                    </GalleryLayoutContextProvider>
                                                </SearchContextProvider>
                                            </DeleteConfirmationContextProvider>
                                        </GalleryContextProvider>
                                    </ImportContextProvider>
                                </AssetDatabaseProvider>
                            </ToastContextProvider>
                        </AppContextProvider>
                    </ConfigContextProvider>
                    </ApiContextProvider>
                </PlatformContextProvider>
            </UuidGeneratorProvider>
        </CssVarsProvider>
    );
}
