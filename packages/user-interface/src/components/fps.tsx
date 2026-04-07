// @ts-ignore
import FPSStats from "react-fps-stats";
import { useEffect } from "react";

const isProduction: boolean = false; //(import.meta.env.MODE === "production");

export function Fps() {

    useEffect(() => { //todo: get rid of this.
        let frameCount = 0;
        let lastTime = performance.now();
        let rafHandle: number;

        function onFrame() {
            frameCount++;
            const now = performance.now();
            if (now - lastTime >= 1000) {
                const fps = Math.round(frameCount * 1000 / (now - lastTime));
                frameCount = 0;
                lastTime = now;
                (window as any).electronAPI?.sendFps(fps);
            }
            rafHandle = requestAnimationFrame(onFrame);
        }

        rafHandle = requestAnimationFrame(onFrame);

        return () => {
            cancelAnimationFrame(rafHandle);
        };
    }, []);

    return (
        <>
            {(isProduction === false)
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
