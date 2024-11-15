import React, { useEffect, useState } from 'react';
import Select from '@mui/joy/Select';
import Option from '@mui/joy/Option';
import { useColorScheme } from '@mui/joy/styles/CssVarsProvider';

export function ModeToggle() {
    const { mode, setMode } = useColorScheme();
    const [mounted, setMounted] = useState(false);

    useEffect(() => {
        setMounted(true);
    }, []);
    if (!mounted) {
        return null;
    }

    return (
        <Select
            value={mode}
            onChange={(event, newMode) => {
                setMode(newMode);
            }}
            sx={{ 
                position: 'fixed',
                top: 60,
                right: 30,
                width: 'max-content',
                zIndex: 1000,
            }}
            >
            <Option value="system">System</Option>
            <Option value="light">Light</Option>
            <Option value="dark">Dark</Option>
        </Select>
    );
}