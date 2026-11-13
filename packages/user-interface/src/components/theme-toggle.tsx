import React from "react";
import IconButton from "@mui/joy/IconButton";
import Dropdown from "@mui/joy/Dropdown";
import Menu from "@mui/joy/Menu";
import MenuButton from "@mui/joy/MenuButton";
import MenuItem from "@mui/joy/MenuItem";
import ListItemDecorator from "@mui/joy/ListItemDecorator";
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
// The choice is applied live via MUI Joy's color scheme and persisted through the app config
// so it survives restarts. "System" follows the OS `prefers-color-scheme` and updates automatically.
//
export function ThemeToggle() {
    const [selectedMode, chooseMode] = useThemeSetting();

    return (
        <Dropdown>
            <MenuButton
                data-id="theme-toggle-button"
                slots={{ root: IconButton }}
                slotProps={{ root: { variant: 'soft', color: 'neutral', title: 'Change theme' } }}
                sx={{ mr: 1 }}
            >
                {renderModeIcon(selectedMode)}
            </MenuButton>
            <Menu data-id="theme-toggle-menu" placement="bottom-end">
                <MenuItem
                    data-id="theme-option-light"
                    selected={selectedMode === 'light'}
                    onClick={() => chooseMode('light')}
                >
                    <ListItemDecorator>
                        <LightMode />
                    </ListItemDecorator>
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
                    <ListItemDecorator>
                        <DarkMode />
                    </ListItemDecorator>
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
                    <ListItemDecorator>
                        <SettingsBrightness />
                    </ListItemDecorator>
                    System
                    {selectedMode === 'system'
                        && <Check sx={{ ml: 'auto' }} fontSize="small" />
                    }
                </MenuItem>
            </Menu>
        </Dropdown>
    );
}
