// @ts-ignore
import FPSStats from "react-fps-stats";

const isProduction: boolean = (import.meta.env.MODE === "production");

export function Fps() {
    return (
        <>
            {(isProduction === false)
                && <FPSStats
                    top="auto"
                    left="auto"
                    right={30}
                    bottom={10}
                />
            }
        </>
    )
}