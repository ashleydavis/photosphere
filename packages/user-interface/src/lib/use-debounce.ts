import { useRef } from "react";

//
// Provides a debounced scheduler and a cancel function that share the same timer.
// Call schedule(fn) to run fn after delayMs of inactivity.
// Call cancel() to discard any pending call (e.g., before an immediate commit).
//
export function useDebounce(delayMs: number): { schedule: (fn: () => void) => void; cancel: () => void } {
    const timerRef = useRef<NodeJS.Timeout | undefined>(undefined);

    function schedule(fn: () => void): void {
        if (timerRef.current !== undefined) {
            clearTimeout(timerRef.current);
        }
        timerRef.current = setTimeout(() => {
            timerRef.current = undefined;
            fn();
        }, delayMs);
    }

    function cancel(): void {
        if (timerRef.current !== undefined) {
            clearTimeout(timerRef.current);
            timerRef.current = undefined;
        }
    }

    return { schedule, cancel };
}
