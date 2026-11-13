import { useEffect, useState } from "react";
import { usePlatform } from "../context/platform-context";

//
// The theme setting the user chose.
//
export type ThemeSetting = 'light' | 'dark' | 'system';

//
// Holds the theme setting from the config file and follows changes of it.
//
export function useThemeSetting(): [ThemeSetting, (setting: ThemeSetting) => Promise<void>] {
    const platform = usePlatform();
    const [setting, setSetting] = useState<ThemeSetting>('system');

    useEffect(() => {
        let active = true;
        platform.getConfig("theme").then(value => {
            if (active && (value === 'light' || value === 'dark' || value === 'system')) {
                setSetting(value);
            }
        }).catch((error: Error) => {
            console.error(`Could not read the theme setting: ${error.message}`);
        });
        const unsubscribe = platform.onConfigChanged(event => {
            if (event.path === "theme") {
                const value = event.value;
                if (value === 'light' || value === 'dark' || value === 'system') {
                    setSetting(value);
                }
            }
        });
        return () => {
            active = false;
            unsubscribe();
        };
    }, [platform]);

    async function choose(nextSetting: ThemeSetting): Promise<void> {
        await platform.setConfig("theme", nextSetting);
    }

    return [setting, choose];
}
