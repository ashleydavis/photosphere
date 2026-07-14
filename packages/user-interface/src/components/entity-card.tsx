import React from 'react';
import Box from '@mui/joy/Box';
import Card from '@mui/joy/Card';
import Typography from '@mui/joy/Typography';
import IconButton from '@mui/joy/IconButton';
import Dropdown from '@mui/joy/Dropdown';
import Menu from '@mui/joy/Menu';
import MenuButton from '@mui/joy/MenuButton';
import MenuItem from '@mui/joy/MenuItem';
import ListItemDecorator from '@mui/joy/ListItemDecorator';
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
// icon buttons per record, which at phone width collapses into truncated headers ("N…", "D…") and
// overlapping text. A card gives the name the whole width, stacks the supporting detail underneath,
// makes the whole card a large tap target for the primary action, and hides the remaining actions
// behind a ⋮ menu with full-height menu rows.
//
export function EntityCard({ title, subtitle, detail, icon, onClick, actions, titleDataId }: IEntityCardProps): JSX.Element {
    return (
        <Card
            variant="soft"
            sx={{
                p: 1.5,
                mb: 1.5,
                borderRadius: 'lg',
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
                        borderRadius: 'md',
                        backgroundColor: 'background.level2',
                        color: 'text.secondary',
                    }}
                    >
                    {icon}
                </Box>

                <Box sx={{ minWidth: 0, flexGrow: 1 }}>
                    <Typography
                        level="title-md"
                        data-id={titleDataId}
                        sx={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}
                        >
                        {title}
                    </Typography>
                    {subtitle
                        && <Typography
                            level="body-sm"
                            sx={{ color: 'text.secondary', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}
                            >
                            {subtitle}
                        </Typography>
                    }
                    {detail
                        && <Typography
                            level="body-xs"
                            sx={{ color: 'text.tertiary', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}
                            >
                            {detail}
                        </Typography>
                    }
                </Box>
            </Box>

            <Dropdown>
                <MenuButton
                    slots={{ root: IconButton }}
                    slotProps={{ root: { variant: 'plain', size: 'lg', 'data-id': 'entity-actions-menu' } }}
                    aria-label={`Actions for ${title}`}
                    >
                    <MoreVert />
                </MenuButton>
                <Menu placement="bottom-end" sx={{ minWidth: 220 }}>
                    {actions.map(action => (
                        <MenuItem
                            key={action.label}
                            data-id={action.dataId}
                            color={action.danger ? 'danger' : undefined}
                            onClick={action.onClick}
                            sx={{ minHeight: 48 }}
                            >
                            <ListItemDecorator>{action.icon}</ListItemDecorator>
                            {action.label}
                        </MenuItem>
                    ))}
                </Menu>
            </Dropdown>
        </Card>
    );
}
