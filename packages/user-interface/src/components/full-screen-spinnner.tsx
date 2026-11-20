
import React from 'react';
import Box from '@mui/material/Box';
import CircularProgress from '@mui/material/CircularProgress';

export function FullscreenSpinner() {
    return (
        <Box
            sx={{
                position: 'fixed',
                top: 0,
                left: 0,
                width: '100%',
                height: '100%',
                backgroundColor: 'var(--color-scrim)',
                backdropFilter: 'blur(var(--backdrop-blur))',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                zIndex: theme => theme.zIndex.modal,
            }}
            >
            <CircularProgress />
        </Box>
    );
};
