// @ts-ignore
import FPSStats from "react-fps-stats";

const isProduction: boolean = false; //(import.meta.env.MODE === "production");

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