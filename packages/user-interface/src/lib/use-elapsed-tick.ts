import { useEffect, useState } from "react";

//
// Re-renders the calling component once a second while it has something to count, and hands back the
// current time to count from.
//
// It lives here rather than in the jobs context because the context wraps the gallery: a clock
// ticking there would repaint every photo on screen once a second for the sake of one line of text.
// Only the two components that show a job's age tick.
//
export function useElapsedTick(active: boolean): number {
    const [now, setNow] = useState<number>(() => Date.now());

    useEffect(() => {
        if (!active) {
            return;
        }

        setNow(Date.now());
        const timer = setInterval(() => setNow(Date.now()), 1000);
        return () => clearInterval(timer);
    }, [active]);

    return now;
}
