import { useEffect, useState } from "react";

//
// Viewport width (in pixels) at and above which the desktop layout is used;
// below it the mobile (compact) layout is used. Set to Tailwind's default `md`
// breakpoint. Adjust this single value to move the mobile/desktop boundary.
//
export const MOBILE_BREAKPOINT_PX = 768;

//
// Returns whether the current viewport is narrow enough for the mobile
// (compact) layout. Tracks the viewport width so the value updates live when
// the window is resized or a device rotates between portrait and landscape.
// This reflects form factor only; it does not indicate the native platform.
//
export function useIsMobile(): boolean {
    const query = `(max-width: ${MOBILE_BREAKPOINT_PX - 1}px)`;
    const [isMobile, setIsMobile] = useState<boolean>(() => window.matchMedia(query).matches);

    useEffect(() => {
        const mediaQuery = window.matchMedia(query);
        const updateIsMobile = (): void => {
            setIsMobile(mediaQuery.matches);
        };
        updateIsMobile();
        mediaQuery.addEventListener("change", updateIsMobile);
        return () => {
            mediaQuery.removeEventListener("change", updateIsMobile);
        };
    }, [query]);

    return isMobile;
}
