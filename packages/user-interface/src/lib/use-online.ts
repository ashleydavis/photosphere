import { useState, useEffect } from 'react';

//
// Checks if the user is online.
//
export function useOnline() {
    // https://developer.mozilla.org/en-US/docs/Web/API/Navigator/onLine
    const [isOnline, setIsOnline] = useState(navigator.onLine);

    useEffect(() => {
        function updateOnlineStatus() {
            setIsOnline(navigator.onLine);
        }

        window.addEventListener('online', updateOnlineStatus);
        window.addEventListener('offline', updateOnlineStatus);

        return () => {
            window.removeEventListener('online', updateOnlineStatus);
            window.removeEventListener('offline', updateOnlineStatus);
        };
    }, []);

    return {
        isOnline
    };
}