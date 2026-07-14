import React from 'react';
import Box from '@mui/joy/Box';
import Button from '@mui/joy/Button';
import IconButton from '@mui/joy/IconButton';
import Typography from '@mui/joy/Typography';
import Dropdown from '@mui/joy/Dropdown';
import Menu from '@mui/joy/Menu';
import MenuButton from '@mui/joy/MenuButton';
import MenuItem from '@mui/joy/MenuItem';
import ListItemDecorator from '@mui/joy/ListItemDecorator';
import { MoreVert, Refresh } from '@mui/icons-material';
import { useIsMobile } from '../lib/use-is-mobile';

//
// One action offered by a page header.
//
export interface IPageHeaderAction {
    // Text shown on the button or in the overflow menu.
    label: string;

    // Icon shown beside the label.
    icon: React.ReactNode;

    // Called when the action is chosen.
    onClick: () => void;

    // The `data-id` used to drive this action from the smoke tests.
    dataId?: string;
}

//
// Props for the MobilePageHeader.
//
export interface IMobilePageHeaderProps {
    // The page title.
    title: string;

    // A short line under the title describing what the page holds (for example how many databases
    // are configured). Gives the header somewhere to breathe on a phone, where the page is
    // otherwise a wall of controls.
    subtitle?: string;

    // The one action the page most wants you to take. Rendered as a solid, full-width button on a
    // phone and as a normal button on desktop.
    primaryAction: IPageHeaderAction;

    // Everything else. Collapsed into an overflow menu on a phone rather than crowding the header.
    secondaryActions: IPageHeaderAction[];

    // Called when the refresh control is used.
    onRefresh: () => void;

    // Whether a refresh is running, which spins the refresh icon.
    refreshing: boolean;
}

//
// The header shared by the management pages (databases, secrets).
//
// On a phone it is laid out as a mobile screen: a large title with a subtitle, a single full-width
// primary action, and every other action folded into an overflow menu. Cramming a title, a refresh
// button, and three labelled buttons into one row is what pushed actions off the side of the screen
// before; a phone header carries one action and hides the rest behind the ⋮ menu.
//
// On a wide screen it stays the familiar row: title on the left, actions on the right.
//
export function MobilePageHeader({ title, subtitle, primaryAction, secondaryActions, onRefresh, refreshing }: IMobilePageHeaderProps): JSX.Element {
    const isMobile = useIsMobile();

    //
    // The spin animation applied to the refresh icon while a refresh is running.
    //
    const spinSx = refreshing
        ? {
            animation: 'spin 0.8s linear infinite',
            '@keyframes spin': {
                from: { transform: 'rotate(0deg)' },
                to: { transform: 'rotate(360deg)' },
            },
        }
        : undefined;

    if (isMobile) {
        return (
            <Box sx={{ mb: 2 }}>
                <Box sx={{ display: 'flex', alignItems: 'flex-start', gap: 1 }}>
                    <Box sx={{ flexGrow: 1, minWidth: 0 }}>
                        <Typography level="h2" sx={{ fontSize: '1.75rem', lineHeight: 1.2 }}>
                            {title}
                        </Typography>
                        {subtitle
                            && <Typography level="body-sm" sx={{ mt: 0.5, color: 'text.tertiary' }}>
                                {subtitle}
                            </Typography>
                        }
                    </Box>

                    <IconButton
                        variant="plain"
                        size="lg"
                        disabled={refreshing}
                        title="Refresh"
                        onClick={onRefresh}
                        >
                        <Refresh sx={spinSx} />
                    </IconButton>

                    <Dropdown>
                        <MenuButton
                            slots={{ root: IconButton }}
                            slotProps={{ root: { variant: 'plain', size: 'lg' } }}
                            aria-label="More actions"
                            >
                            <MoreVert />
                        </MenuButton>
                        <Menu placement="bottom-end" sx={{ minWidth: 220 }}>
                            {secondaryActions.map(action => (
                                <MenuItem
                                    key={action.label}
                                    data-id={action.dataId}
                                    onClick={action.onClick}
                                    sx={{ minHeight: 48 }}
                                    >
                                    <ListItemDecorator>{action.icon}</ListItemDecorator>
                                    {action.label}
                                </MenuItem>
                            ))}
                        </Menu>
                    </Dropdown>
                </Box>

                <Button
                    data-id={primaryAction.dataId}
                    startDecorator={primaryAction.icon}
                    onClick={primaryAction.onClick}
                    size="lg"
                    sx={{ mt: 2, width: '100%', minHeight: 52, borderRadius: 'md' }}
                    >
                    {primaryAction.label}
                </Button>
            </Box>
        );
    }

    return (
        <Box sx={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 1, mb: 2 }}>
            <Typography level="h3">{title}</Typography>
            <Box sx={{ flexGrow: 1 }} />
            <IconButton
                variant="outlined"
                disabled={refreshing}
                title="Refresh"
                onClick={onRefresh}
                >
                <Refresh sx={spinSx} />
            </IconButton>
            <Button
                data-id={primaryAction.dataId}
                startDecorator={primaryAction.icon}
                onClick={primaryAction.onClick}
                >
                {primaryAction.label}
            </Button>
            {secondaryActions.map(action => (
                <Button
                    key={action.label}
                    data-id={action.dataId}
                    variant="outlined"
                    onClick={action.onClick}
                    sx={{ whiteSpace: 'nowrap' }}
                    >
                    {action.label}
                </Button>
            ))}
        </Box>
    );
}
