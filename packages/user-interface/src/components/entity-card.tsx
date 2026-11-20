import React, { useState } from 'react';
import Box from '@mui/material/Box';
import Card from '@mui/material/Card';
import Typography from '@mui/material/Typography';
import IconButton from '@mui/material/IconButton';
import Menu from '@mui/material/Menu';
import MenuItem from '@mui/material/MenuItem';
import ListItemIcon from '@mui/material/ListItemIcon';
import { MoreVert } from '@mui/icons-material';

//
// One action offered by an entity card, shown in the card's overflow menu.
//
export interface IEntityCardAction {
    // Text shown in the overflow menu.
    label: string;

    // Icon shown beside the label.
    icon: React.ReactNode;

    // Called when the action is chosen.
    onClick: () => void;

    // The `data-id` used to drive this action from the smoke tests.
    dataId?: string;

    // Renders the action in the danger colour (used for destructive actions such as remove).
    danger?: boolean;
}

//
// Props for the EntityCard.
//
export interface IEntityCardProps {
    // The entity's name, shown as the card's headline.
    title: string;

    // A short line under the title (a description, or the entity's type).
    subtitle?: string;

    // A second, quieter line under the subtitle (a filesystem path or an origin).
    detail?: string;

    // Icon shown at the leading edge of the card, identifying the kind of entity.
    icon: React.ReactNode;

    // Called when the body of the card is tapped, which performs the entity's primary action
    // (opening a database, viewing a secret). Omitted when the entity has no primary action.
    onClick?: () => void;

    // Every other action, reached through the card's ⋮ menu.
    actions: IEntityCardAction[];

    // The `data-id` used to find this card's title from the smoke tests.
    titleDataId?: string;
}

//
// A single entity (a database, a secret) presented as a card.
//
// This is the mobile replacement for a table row. A table needs one column per field and a row of
// icon buttons per record, which at mobile width collapses into truncated headers ("N…", "D…") and
// overlapping text. A card gives the name the whole width, stacks the supporting detail underneath,
// makes the whole card a large tap target for the primary action, and hides the remaining actions
// behind a ⋮ menu with full-height menu rows.
//
export function EntityCard({ title, subtitle, detail, icon, onClick, actions, titleDataId }: IEntityCardProps): React.JSX.Element {
    //
    // The ⋮ button the overflow menu hangs from while it is open, or undefined while it is closed.
    //
    const [menuAnchor, setMenuAnchor] = useState<HTMLElement | undefined>(undefined);

    return (
        <Card
            elevation={0}
            sx={{
                p: 1.5,
                mb: 1.5,
                borderRadius: 3,
                bgcolor: 'action.hover',
                display: 'flex',
                flexDirection: 'row',
                alignItems: 'center',
                gap: 1.5,
                // The card's own tap target: comfortably above the 48px minimum.
                minHeight: 72,
            }}
            >
            <Box
                onClick={onClick}
                sx={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 1.5,
                    flexGrow: 1,
                    minWidth: 0,
                    cursor: onClick ? 'pointer' : 'default',
                }}
                >
                <Box
                    sx={{
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        flexShrink: 0,
                        width: 44,
                        height: 44,
                        borderRadius: 2,
                        backgroundColor: 'action.selected',
                        color: 'text.secondary',
                    }}
                    >
                    {icon}
                </Box>

                <Box sx={{ minWidth: 0, flexGrow: 1 }}>
                    <Typography
                        variant="subtitle1"
                        data-id={titleDataId}
                        sx={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}
                        >
                        {title}
                    </Typography>
                    {subtitle
                        && <Typography
                            variant="body2"
                            sx={{ color: 'text.secondary', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}
                            >
                            {subtitle}
                        </Typography>
                    }
                    {detail
                        && <Typography
                            variant="caption"
                            sx={{
                                display: 'block',
                                color: 'text.secondary',
                                overflow: 'hidden',
                                textOverflow: 'ellipsis',
                                whiteSpace: 'nowrap',
                            }}
                            >
                            {detail}
                        </Typography>
                    }
                </Box>
            </Box>

            <IconButton
                data-id="entity-actions-menu"
                size="large"
                aria-label={`Actions for ${title}`}
                onClick={event => setMenuAnchor(event.currentTarget)}
                >
                <MoreVert />
            </IconButton>
            <Menu
                open={menuAnchor !== undefined}
                anchorEl={menuAnchor}
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
                            minWidth: 220,
                        },
                    },
                }}
                >
                {actions.map(action => (
                    <MenuItem
                        key={action.label}
                        data-id={action.dataId}
                        onClick={() => {
                            setMenuAnchor(undefined);
                            action.onClick();
                        }}
                        sx={{
                            minHeight: 48,
                            color: action.danger ? 'error.main' : undefined,
                        }}
                        >
                        <ListItemIcon
                            sx={{
                                color: 'inherit',
                            }}
                            >
                            {action.icon}
                        </ListItemIcon>
                        {action.label}
                    </MenuItem>
                ))}
            </Menu>
        </Card>
    );
}
