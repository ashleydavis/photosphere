import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { usePlatform } from "./platform-context";
import { useConfig } from "./config-context";
import { log } from "utils";

//
// Config persistence key for the developer-mode flag.
//
const DEVELOPER_MODE_CONFIG_KEY = "developerMode";

//
// Config persistence key for the FPS-indicator flag. Reused from the former
// desktop Developer menu so previously persisted values continue to apply.
//
const SHOW_FPS_INDICATOR_CONFIG_KEY = "showFpsIndicator";

//
// Config persistence key for the developer-tools open flag. When true the
// developer tools are reopened on startup.
//
const DEV_TOOLS_OPEN_CONFIG_KEY = "devToolsOpen";

//
// Reactive developer-mode configuration: whether developer mode is enabled and
// the developer-tool settings it reveals (the FPS overlay and the developer
// tools). Each value is persisted to config so it survives a restart. Kept
// separate from the app data layer since it is purely developer tooling.
//
export interface IDeveloperContext {
    //
    // True while developer mode is enabled (reveals developer tools in the UI).
    //
    developerMode: boolean;

    //
    // Turns developer mode on and persists the flag.
    //
    enableDeveloperMode: () => void;

    //
    // Turns developer mode off and persists the flag.
    //
    disableDeveloperMode: () => void;

    //
    // True while the FPS-indicator overlay should be shown.
    //
    showFpsIndicator: boolean;

    //
    // Toggles the FPS-indicator overlay and persists the flag.
    //
    toggleShowFpsIndicator: () => void;

    //
    // True while the developer tools are open. Persisted and reopened on startup.
    //
    devToolsOpen: boolean;

    //
    // Toggles the developer tools (native inspector on desktop, in-page console
    // on web/mobile), persisting the new state so it is reapplied on startup.
    //
    toggleDevTools: () => void;
}

const DeveloperContext = createContext<IDeveloperContext | undefined>(undefined);

//
// Props for the developer-context provider.
//
export interface IDeveloperContextProviderProps {
    //
    // The subtree that can read the developer configuration.
    //
    children: ReactNode | ReactNode[];
}

//
// Provides the reactive developer-mode configuration to its subtree.
//
export function DeveloperContextProvider({ children }: IDeveloperContextProviderProps) {
    const platform = usePlatform();
    const config = useConfig();

    //
    // Whether developer mode is currently enabled. Loaded from persistent config on mount.
    //
    const [developerMode, setDeveloperMode] = useState<boolean>(false);

    //
    // Whether the FPS-indicator overlay is currently shown. Loaded from persistent config on mount.
    //
    const [showFpsIndicator, setShowFpsIndicator] = useState<boolean>(false);

    //
    // Whether the developer tools are currently open. Loaded from persistent config on mount
    // and reapplied to the platform so the tools reopen on startup.
    //
    const [devToolsOpen, setDevToolsOpen] = useState<boolean>(false);

    //
    // Enables developer mode and persists the change (fire and forget).
    //
    function enableDeveloperMode(): void {
        setDeveloperMode(true);
        config.set<boolean>(DEVELOPER_MODE_CONFIG_KEY, true)
            .catch(err => log.exception("Failed to persist developer mode:", err as Error));
        log.event("Developer mode enabled");
    }

    //
    // Disables developer mode and persists the change (fire and forget).
    //
    function disableDeveloperMode(): void {
        setDeveloperMode(false);
        config.set<boolean>(DEVELOPER_MODE_CONFIG_KEY, false)
            .catch(err => log.exception("Failed to persist developer mode:", err as Error));
        log.event("Developer mode disabled");
    }

    //
    // Toggles the FPS indicator and persists the change (fire and forget).
    //
    function toggleShowFpsIndicator(): void {
        const nextValue = !showFpsIndicator;
        setShowFpsIndicator(nextValue);
        config.set<boolean>(SHOW_FPS_INDICATOR_CONFIG_KEY, nextValue)
            .catch(err => log.exception("Failed to persist FPS indicator setting:", err as Error));
        log.event(`FPS indicator ${nextValue ? "enabled" : "disabled"}`);
    }

    //
    // Toggles the developer tools and persists the new state (fire and forget).
    // The platform applies the actual inspector; the persisted flag reopens it on startup.
    //
    function toggleDevTools(): void {
        const nextValue = !devToolsOpen;
        setDevToolsOpen(nextValue);
        platform.toggleDevTools();
        config.set<boolean>(DEV_TOOLS_OPEN_CONFIG_KEY, nextValue)
            .catch(err => log.exception("Failed to persist developer tools setting:", err as Error));
        log.event(`Developer tools ${nextValue ? "opened" : "closed"}`);
    }

    useEffect(() => {
        config.get<boolean>(DEVELOPER_MODE_CONFIG_KEY).then(value => {
            if (value !== undefined) {
                setDeveloperMode(value);
            }
        });
    }, []);

    useEffect(() => {
        config.get<boolean>(SHOW_FPS_INDICATOR_CONFIG_KEY).then(value => {
            if (value !== undefined) {
                setShowFpsIndicator(value);
            }
        });
    }, []);

    useEffect(() => {
        config.get<boolean>(DEV_TOOLS_OPEN_CONFIG_KEY).then(value => {
            if (value === true) {
                setDevToolsOpen(true);
                // Reopen the developer tools on startup. Both inspectors start closed
                // after a restart, so a single toggle brings them back to the open state.
                platform.toggleDevTools();
            }
        });
    }, []);

    //
    // Keep the toggle in sync with the real developer-tools state reported by the
    // host, including when the user closes the tools with their native close
    // button. Persist the reported state so a restart reopens (or leaves closed)
    // the tools to match. No-op on platforms that never emit this event.
    //
    useEffect(() => {
        return platform.onPlatformEvent(event => {
            if (event.type === "devtools-state") {
                setDevToolsOpen(event.open);
                config.set<boolean>(DEV_TOOLS_OPEN_CONFIG_KEY, event.open)
                    .catch(err => log.exception("Failed to persist developer tools setting:", err as Error));
            }
        });
    }, [platform]);

    const value: IDeveloperContext = {
        developerMode,
        enableDeveloperMode,
        disableDeveloperMode,
        showFpsIndicator,
        toggleShowFpsIndicator,
        devToolsOpen,
        toggleDevTools,
    };

    return (
        <DeveloperContext.Provider value={value} >
            {children}
        </DeveloperContext.Provider>
    );
}

//
// Get the developer context.
//
export function useDeveloper() {
    const context = useContext(DeveloperContext);
    if (!context) {
        throw new Error(`DeveloperContext is not set! Add DeveloperContextProvider to the component tree.`);
    }
    return context;
}
