import React, { ReactNode } from "react";
import { CssVarsProvider } from "@mui/joy/styles/CssVarsProvider";
import type { IUuidGenerator } from "utils";
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
import { ToastContextProvider } from "../../context/toast-context";
import { ConfigContextProvider, createConfig } from "../../context/config-context";
import {
    AssetDatabaseContext,
    type IAssetDatabase,
} from "../../context/asset-database-source";
import { GallerySourceContext } from "../../context/gallery-source";
import type { IGalleryItem } from "../../lib/gallery-item";
import { Observable } from "../../lib/subscription";
import { ImportContextProvider } from "../../context/import-context";
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
        micro: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
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
        micro: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
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

    return {
        isLoading: false,
        isSyncing: false,
        isWorking: false,
        isReadOnly: false,
        getAssets: () => assetMap,
        onReset: new Observable<void>(),
        onNewItems: new Observable<IGalleryItem[]>(),
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
    // Optional override for the asset database context. Defaults to an
    // in-memory mock with no assets loaded.
    //
    assetDatabase?: IAssetDatabase;
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
export function MockProviders({
    children,
    uuidGenerator,
    platform,
    assetDatabase,
}: IMockProvidersProps) {
    const platformValue = platform || mockPlatform();
    const uuidGeneratorValue = uuidGenerator || mockUuidGenerator();
    const databaseValue = assetDatabase || mockAssetDatabase();

    //
    // In-memory config so any story that consumes useConfig() gets a real
    // implementation instead of crashing on missing context.
    //
    const configStore: { [key: string]: unknown } = {};
    const config = createConfig(
        async (key: string) => configStore[key],
        async (key: string, value: unknown) => { configStore[key] = value; },
    );

    return (
        <CssVarsProvider>
            <UuidGeneratorProvider value={uuidGeneratorValue}>
                <PlatformContextProvider value={platformValue}>
                    <ConfigContextProvider value={config}>
                        <AppContextProvider>
                            <ToastContextProvider>
                                <AssetDatabaseContext.Provider value={databaseValue}>
                                    <GallerySourceContext.Provider value={databaseValue}>
                                        <ImportContextProvider>
                                            <GalleryContextProvider>
                                                <DeleteConfirmationContextProvider>
                                                    <SearchContextProvider>
                                                        <GalleryLayoutContextProvider>
                                                            {children}
                                                        </GalleryLayoutContextProvider>
                                                    </SearchContextProvider>
                                                </DeleteConfirmationContextProvider>
                                            </GalleryContextProvider>
                                        </ImportContextProvider>
                                    </GallerySourceContext.Provider>
                                </AssetDatabaseContext.Provider>
                            </ToastContextProvider>
                        </AppContextProvider>
                    </ConfigContextProvider>
                </PlatformContextProvider>
            </UuidGeneratorProvider>
        </CssVarsProvider>
    );
}
