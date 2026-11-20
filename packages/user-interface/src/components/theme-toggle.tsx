import React, { useState } from "react";
import IconButton from "@mui/material/IconButton";
import Menu from "@mui/material/Menu";
import MenuItem from "@mui/material/MenuItem";
import ListItemIcon from "@mui/material/ListItemIcon";
import LightMode from "@mui/icons-material/LightMode";
import DarkMode from "@mui/icons-material/DarkMode";
import SettingsBrightness from "@mui/icons-material/SettingsBrightness";
import Check from "@mui/icons-material/Check";
import { ThemeSetting, useThemeSetting } from "../lib/use-theme-setting";

//
// The set of theme modes the user can choose between.
//
type ThemeMode = ThemeSetting;

//
// Renders the icon that best represents the currently selected theme mode.
// Each mode shows its own icon, including "system" which shows the dedicated system icon.
//
function renderModeIcon(mode: ThemeMode): React.ReactNode {
    if (mode === 'light') {
        return <LightMode />;
    }

    if (mode === 'dark') {
        return <DarkMode />;
    }

    //
    // System mode: show the dedicated system icon.
    //
    return <SettingsBrightness />;
}

//
// A nav bar control that lets the user switch between light, dark and system themes.
// The choice is applied live via MUI's color scheme and persisted through the app config
// so it survives restarts. "System" follows the OS `prefers-color-scheme` and updates automatically.
//
export function ThemeToggle() {
    const [selectedMode, setSelectedMode] = useThemeSetting();

    //
    // The button the menu hangs from while it is open, and undefined while it is closed.
    //
    const [menuAnchor, setMenuAnchor] = useState<HTMLElement | undefined>(undefined);

    //
    // Applies the chosen mode and closes the menu.
    //
    function chooseMode(mode: ThemeMode): void {
        setSelectedMode(mode);
        setMenuAnchor(undefined);
    }

    return (
        <>
            <IconButton
                data-id="theme-toggle-button"
                title="Change theme"
                onClick={event => setMenuAnchor(event.currentTarget)}
                sx={{
                    mr: 1,
                    borderRadius: 2,
                    backgroundColor: 'action.selected',
                }}
            >
                {renderModeIcon(selectedMode)}
            </IconButton>
            <Menu
                data-id="theme-toggle-menu"
                anchorEl={menuAnchor}
                open={menuAnchor !== undefined}
                onClose={() => setMenuAnchor(undefined)}
                anchorOrigin={{
                    vertical: 'bottom',
                    horizontal: 'right',
                }}
                transformOrigin={{
                    vertical: 'top',
                    horizontal: 'right',
                }}
            >
                <MenuItem
                    data-id="theme-option-light"
                    selected={selectedMode === 'light'}
                    onClick={() => chooseMode('light')}
                >
                    <ListItemIcon>
                        <LightMode />
                    </ListItemIcon>
                    Light
                    {selectedMode === 'light'
                        && <Check sx={{ ml: 'auto' }} fontSize="small" />
                    }
                </MenuItem>
                <MenuItem
                    data-id="theme-option-dark"
                    selected={selectedMode === 'dark'}
                    onClick={() => chooseMode('dark')}
                >
                    <ListItemIcon>
                        <DarkMode />
                    </ListItemIcon>
                    Dark
                    {selectedMode === 'dark'
                        && <Check sx={{ ml: 'auto' }} fontSize="small" />
                    }
                </MenuItem>
                <MenuItem
                    data-id="theme-option-system"
                    selected={selectedMode === 'system'}
                    onClick={() => chooseMode('system')}
                >
                    <ListItemIcon>
                        <SettingsBrightness />
                    </ListItemIcon>
                    System
                    {selectedMode === 'system'
                        && <Check sx={{ ml: 'auto' }} fontSize="small" />
                    }
                </MenuItem>
            </Menu>
        </>
    );
}
