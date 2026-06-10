// @ts-ignore
import FPSStats from "react-fps-stats";
import { useEffect, useState } from "react";
import { useConfig } from "../context/config-context";
import { usePlatform } from "../context/platform-context";

//
// Renders the FPS indicator overlay when the persisted `showFpsIndicator` setting is enabled.
// The initial value is loaded from config and re-read live when the "Show FPS Indicator"
// developer menu item is toggled (via the `toggle-fps` menu action). Defaults to not shown.
//
export function Fps() {

    // Whether the FPS indicator overlay should currently be shown.
    const [showFpsIndicator, setShowFpsIndicator] = useState<boolean>(false);

    const config = useConfig();
    const platform = usePlatform();

    //
    // Load the initial value of the setting from config.
    //
    useEffect(() => {
        let isMounted = true;
        config.get<boolean>("showFpsIndicator")
            .then(value => {
                if (isMounted) {
                    setShowFpsIndicator(value === true);
                }
            });

        return () => {
            isMounted = false;
        };
    }, [config]);

    //
    // Re-read the setting when the "Show FPS Indicator" developer menu item is toggled.
    //
    useEffect(() => {
        const unsubscribe = platform.onMenuAction(action => {
            if (action === "toggle-fps") {
                config.get<boolean>("showFpsIndicator")
                    .then(value => {
                        setShowFpsIndicator(value === true);
                    });
            }
        });

        return unsubscribe;
    }, [platform, config]);

    return (
        <>
            {showFpsIndicator
                && <FPSStats
                    top="auto"
                    left="auto"
                    right={70}
                    bottom={10}
                />
            }
        </>
    )
}
