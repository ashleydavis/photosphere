import React, { useState } from 'react';
import Box from '@mui/material/Box';
import Button from '@mui/material/Button';
import IconButton from '@mui/material/IconButton';
import Typography from '@mui/material/Typography';
import Menu from '@mui/material/Menu';
import MenuItem from '@mui/material/MenuItem';
import ListItemIcon from '@mui/material/ListItemIcon';
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
    // are configured). Gives the header somewhere to breathe on a mobile, where the page is
    // otherwise a wall of controls.
    subtitle?: string;

    // The one action the page most wants you to take. Rendered as a solid, full-width button on a
    // mobile and as a normal button on desktop.
    primaryAction: IPageHeaderAction;

    // Everything else. Collapsed into an overflow menu on a mobile rather than crowding the header.
    secondaryActions: IPageHeaderAction[];

    // Called when the refresh control is used.
    onRefresh: () => void;

    // Whether a refresh is running, which spins the refresh icon.
    refreshing: boolean;
}

//
// The header shared by the management pages (databases, secrets), drawn as the style guide's list
// page header: the title over a muted line saying what the page holds, then the actions.
//
// On a mobile the title stands alone with Refresh and the ⋮ menu beside it, holding every
// secondary action, and the primary action fills the width below. Cramming a title, a refresh
// button and three labelled buttons into one row is what pushed actions off the side of the
// screen.
//
// On a wide screen the actions sit in a row under the title, as --list-header-direction and
// --list-header-align set.
//
export function MobilePageHeader({ title, subtitle, primaryAction, secondaryActions, onRefresh, refreshing }: IMobilePageHeaderProps): React.JSX.Element {
    const isMobile = useIsMobile();

    //
    // The button the overflow menu hangs from while it is open, and undefined while it is closed.
    //
    const [menuAnchor, setMenuAnchor] = useState<HTMLElement | undefined>(undefined);

    //
    // The spin animation applied to the refresh icon while a refresh is running.
    //
    const spinSx = refreshing
        ? {
            animation: 'page-header-spin var(--duration-slow) linear infinite',
            '@keyframes page-header-spin': {
                from: {
                    transform: 'rotate(0deg)',
                },
                to: {
                    transform: 'rotate(360deg)',
                },
            },
        }
        : undefined;

    const refreshButton = (
        <IconButton
            disabled={refreshing}
            title="Refresh"
            onClick={onRefresh}
            sx={isMobile
                ? {
                    width: 'var(--button-height-lg)',
                    height: 'var(--button-height-lg)',
                }
                : undefined
            }
            >
            <Refresh fontSize="inherit" sx={spinSx} />
        </IconButton>
    );

    const heading = (
        <Box sx={{
            display: 'flex',
            flexDirection: 'column',
            minWidth: 0,
        }}>
            <Typography
                component={isMobile ? 'h2' : 'h3'}
                sx={{
                    margin: 0,
                    fontFamily: 'var(--font-heading)',
                    fontSize: 'var(--page-title-size)',
                    fontWeight: 'var(--weight-bold)',
                    lineHeight: 'var(--leading-tight)',
                    color: 'var(--color-text)',
                }}
                >
                {title}
            </Typography>
            {subtitle
                && <Typography
                    component="span"
                    sx={{
                        marginTop: 'var(--space-1)',
                        fontSize: 'var(--text-sm)',
                        color: 'var(--color-text-muted)',
                    }}
                    >
                    {subtitle}
                </Typography>
            }
        </Box>
    );

    if (isMobile) {
        return (
            <Box sx={{
                display: 'flex',
                flexDirection: 'column',
                gap: 'var(--space-4)',
                marginBottom: 'var(--space-4)',
            }}>
                <Box sx={{
                    display: 'flex',
                    alignItems: 'flex-start',
                    justifyContent: 'space-between',
                    gap: 'var(--space-2)',
                }}>
                    {heading}

                    <Box sx={{
                        display: 'flex',
                        flex: 'none',
                        gap: 'var(--space-2)',
                    }}>
                        {refreshButton}

                        <IconButton
                            data-id="page-actions-menu"
                            aria-label="More actions"
                            onClick={event => setMenuAnchor(event.currentTarget)}
                            sx={{
                                width: 'var(--button-height-lg)',
                                height: 'var(--button-height-lg)',
                            }}
                            >
                            <MoreVert fontSize="inherit" />
                        </IconButton>
                    </Box>
                    <Menu
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
                        slotProps={{
                            paper: {
                                sx: {
                                    minWidth: 'calc(var(--space-8) * 7)',
                                },
                            },
                        }}
                        >
                        {secondaryActions.map(action => (
                            <MenuItem
                                key={action.label}
                                data-id={action.dataId}
                                onClick={() => {
                                    setMenuAnchor(undefined);
                                    action.onClick();
                                }}
                                sx={{
                                    minHeight: 'var(--menu-item-height)',
                                }}
                                >
                                <ListItemIcon>{action.icon}</ListItemIcon>
                                {action.label}
                            </MenuItem>
                        ))}
                    </Menu>
                </Box>

                <Button
                    data-id={primaryAction.dataId}
                    variant="contained"
                    startIcon={primaryAction.icon}
                    onClick={primaryAction.onClick}
                    size="large"
                    fullWidth={true}
                    >
                    {primaryAction.label}
                </Button>
            </Box>
        );
    }

    return (
        <Box sx={{
            display: 'flex',
            flexWrap: 'wrap',
            flexDirection: 'var(--list-header-direction)',
            alignItems: 'var(--list-header-align)',
            justifyContent: 'space-between',
            gap: 'var(--space-4)',
            marginBottom: 'var(--space-4)',
        }}>
            {heading}
            <Box sx={{
                display: 'flex',
                flexWrap: 'wrap',
                alignItems: 'center',
                gap: 'var(--space-2)',
            }}>
                {refreshButton}
                {secondaryActions.map(action => (
                    <Button
                        key={action.label}
                        data-id={action.dataId}
                        variant="outlined"
                        startIcon={action.icon}
                        onClick={action.onClick}
                        sx={{
                            whiteSpace: 'nowrap',
                        }}
                        >
                        {action.label}
                    </Button>
                ))}
                <Button
                    data-id={primaryAction.dataId}
                    variant="contained"
                    startIcon={primaryAction.icon}
                    onClick={primaryAction.onClick}
                    >
                    {primaryAction.label}
                </Button>
            </Box>
        </Box>
    );
}
