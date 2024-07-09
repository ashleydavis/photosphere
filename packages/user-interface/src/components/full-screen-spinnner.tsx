import React from 'react';
import CircularProgress from '@mui/joy/CircularProgress';

export function FullscreenSpinner() {
    return (
        <div
            style={{
                position: 'fixed',
                top: 0,
                left: 0,
                width: '100%',
                height: '100%',
                backgroundColor: 'rgba(0, 0, 0, 0.5)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                zIndex: 1300,
            }}
            >
            <CircularProgress variant="soft" />
        </div>
    );
};
