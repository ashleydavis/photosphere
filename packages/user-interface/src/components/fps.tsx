// @ts-ignore
import FPSStats from "react-fps-stats";
import { useDeveloper } from "../context/developer-context";

//
// Renders the FPS indicator overlay when the `showFpsIndicator` value from
// the developer context is enabled. The value is config-backed reactive state,
// so the overlay shows and hides immediately when the developer-page toggle
// flips it. Defaults to not shown.
//
export function Fps() {

    const { showFpsIndicator } = useDeveloper();

    return (
        <>
            {showFpsIndicator
                && <div data-id="fps-indicator">
                    <FPSStats
                        top="auto"
                        left="auto"
                        right={70}
                        bottom={10}
                    />
                </div>
            }
        </>
    )
}
