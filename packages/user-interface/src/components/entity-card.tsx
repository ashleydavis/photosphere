import React, { useState } from 'react';
import Box from '@mui/material/Box';
import Card from '@mui/material/Card';
import Chip from '@mui/material/Chip';
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

    // Draws the title in the monospace font, for an entity whose name is an identifier, such as a
    // secret, as the style guide's secret card does.
    monoTitle: boolean;

    // Draws the subtitle as a small accent chip rather than a line of muted text, for a subtitle
    // that names the entity's kind, such as a secret's type.
    subtitleChip: boolean;
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
export function EntityCard({ title, subtitle, detail, icon, onClick, actions, titleDataId, monoTitle, subtitleChip }: IEntityCardProps): React.JSX.Element {
    //
    // The ⋮ button the overflow menu hangs from while it is open, or undefined while it is closed.
    //
    const [menuAnchor, setMenuAnchor] = useState<HTMLElement | undefined>(undefined);

    return (
        <Card
            elevation={0}
            sx={{
                padding: 'var(--space-3)',
                marginBottom: 'var(--space-3)',
                background: 'var(--color-panel)',
                border: '1px solid var(--color-border)',
                borderRadius: 'var(--radius-md)',
                boxShadow: 'var(--shadow-raised)',
                display: 'flex',
                flexDirection: 'row',
                alignItems: 'center',
                gap: 'var(--space-3)',
            }}
            >
            <Box
                onClick={onClick}
                sx={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 'var(--space-3)',
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
                        width: 'calc(var(--space-8) + var(--space-2))',
                        height: 'calc(var(--space-8) + var(--space-2))',
                        background: 'var(--color-chip-bg)',
                        color: 'var(--color-accent)',
                        border: '1px solid var(--color-chip-border)',
                        borderRadius: 'var(--radius-md)',
                        fontSize: 'var(--icon-lg)',
                        '& .MuiSvgIcon-root': {
                            fontSize: 'inherit',
                        },
                    }}
                    >
                    {icon}
                </Box>

                <Box sx={{ minWidth: 0, flexGrow: 1 }}>
                    <Typography
                        variant="subtitle1"
                        data-id={titleDataId}
                        sx={{
                            fontFamily: monoTitle ? 'var(--font-mono)' : 'var(--font-sans)',
                            fontSize: 'var(--text-md)',
                            fontWeight: 'var(--weight-bold)',
                            overflow: 'hidden',
                            textOverflow: 'ellipsis',
                            whiteSpace: 'nowrap',
                        }}
                        >
                        {title}
                    </Typography>
                    {subtitle && subtitleChip
                        && <Chip
                            size="small"
                            label={subtitle}
                            sx={{
                                minHeight: 'var(--space-6)',
                                marginTop: 'var(--space-1)',
                                fontSize: 'var(--text-xs)',
                                fontWeight: 'var(--weight-bold)',
                            }}
                            />
                    }
                    {subtitle && !subtitleChip
                        && <Typography
                            variant="body2"
                            sx={{
                                color: 'var(--color-text-muted)',
                                fontSize: 'var(--text-sm)',
                                overflow: 'hidden',
                                textOverflow: 'ellipsis',
                                whiteSpace: 'nowrap',
                            }}
                            >
                            {subtitle}
                        </Typography>
                    }
                    {detail
                        && <Typography
                            variant="caption"
                            sx={{
                                display: 'block',
                                color: 'var(--color-text-muted)',
                                fontFamily: 'var(--font-mono)',
                                fontSize: 'var(--text-xs)',
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
                            minWidth: 'calc(var(--space-8) * 7)',
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
                            color: action.danger ? 'var(--color-danger)' : undefined,
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
