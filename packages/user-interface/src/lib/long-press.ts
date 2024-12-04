import React, { useState, useRef, useCallback } from "react";

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

interface ITouchCoordinates {
    x: number;
    y: number;
}

export function useLongPress({ onLongPress, onClick, delay }: ILongPressProps) {

    const isLongPress = useRef<boolean>(false);
    const timeoutRef = useRef<NodeJS.Timeout | undefined>(undefined);
    const startPos = useRef<ITouchCoordinates | undefined>(undefined);

    function onTouchStart(event: React.TouchEvent) {
        startPos.current = {
            x: event.touches[0].clientX,
            y: event.touches[0].clientY,
        };
        timeoutRef.current = setTimeout(() => {
            isLongPress.current = true;
            onLongPress();
        }, delay);
    }
    
    function onTouchEnd() {
        if (timeoutRef.current === undefined) {
            // Not active.
            return;
        }

        clearTimeout(timeoutRef.current);
        timeoutRef.current = undefined;

        if (!isLongPress.current) {
            onClick();
        }
        isLongPress.current = false;
    }

    function onTouchMove(event: React.TouchEvent) {
        if (timeoutRef.current === undefined) {
            // Not pressing.
            return;
        }

        // If we moved further than 10 pixels, cancel the long press.
        const distance = {
            x: Math.abs(event.touches[0].clientX - startPos.current!.x),
            y: Math.abs(event.touches[0].clientY - startPos.current!.y),
        };
        if (distance.x > 10 || distance.y > 10) {
            clearTimeout(timeoutRef.current);
            timeoutRef.current = undefined;
            isLongPress.current = false;
        }
    }

    function onContextMenu(e: React.MouseEvent) {
        e.preventDefault();
    }

    return {
        longPressHandlers: {
            onTouchStart,
            onTouchEnd,
            onTouchMove,
            onContextMenu,
        },
    };
};
