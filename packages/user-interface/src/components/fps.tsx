// @ts-ignore
import FPSStats from "react-fps-stats";
import { useDeveloper } from "../context/developer-context";
import { useIsMobile } from "../lib/use-is-mobile";

//
// Renders the FPS indicator overlay when the `showFpsIndicator` value from
// the developer context is enabled. The value is config-backed reactive state,
// so the overlay shows and hides immediately when the developer-page toggle
// flips it. Defaults to not shown.
//
export function Fps() {

    const { showFpsIndicator } = useDeveloper();

    //
    // Lifts the indicator above the tab bar at the foot of the screen on a mobile.
    //
    const isMobile = useIsMobile();

    return (
        <>
            {showFpsIndicator
                && <div data-id="fps-indicator">
                    <FPSStats
                        top="auto"
                        left="auto"
                        right="calc(var(--space-8) * 2 + var(--space-2))"
                        bottom={isMobile ? "calc(var(--space-8) * 2 + var(--space-2))" : "var(--space-2)"}
                    />
                </div>
            }
        </>
    )
}
