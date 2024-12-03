import { useState, useRef, useCallback } from "react";

export interface ILongPressProps {
    //
    // Event raised when a long press has been detected.
    //
    onLongPress: () => void;

    //
    // Event raised when a click has been detected.
    //
    onClick: () => void;

    //
    // The delay before a long press is detected.
    //
    delay: number;
}

export function useLongPress({ onLongPress, onClick, delay }: ILongPressProps) {

    const [isLongPress, setIsLongPress] = useState(false); //todo: can this be a ref?
    const timeoutRef = useRef<NodeJS.Timeout | null>(null);

    const start = useCallback(() => {
        timeoutRef.current = setTimeout(() => {
            setIsLongPress(true);
            onLongPress();
        }, delay);
    }, [onLongPress, delay]);

    const clear = useCallback(() => {
        if (timeoutRef.current) {
            clearTimeout(timeoutRef.current);
        }
        if (!isLongPress) {
            onClick();
        }
        setIsLongPress(false);
    }, [isLongPress, onClick]);

    const onTouchStart = useCallback(() => start(), [start]);
    const onTouchEnd = useCallback(() => clear(), [clear]);

    function onContextMenu(e: React.MouseEvent) {
        e.preventDefault();
    }

    return {
        longPressHandlers: {
            onTouchStart,
            onTouchEnd,
            onContextMenu,
        },
    };
};
