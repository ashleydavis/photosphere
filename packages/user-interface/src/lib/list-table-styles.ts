//
// Holds the look of the style guide's list table, shared by the desktop tables of the Databases and
// Secrets pages so the two cannot drift apart.
//

import type { SxProps, Theme } from '@mui/material/styles';

//
// Draws a desktop management table as the style guide's list table: a quiet head on the raised
// surface, rows parted by divider lines that take the hover colour under the pointer, muted and
// monospace columns for the supporting detail (cells with the `list-table-muted` and
// `list-table-mono` classes), and the row's icon buttons spaced apart with the last one, the
// dangerous one, set further off at the right so it is harder to hit by accident. Pass it as the
// `sx` of a MUI Table.
//
export const LIST_TABLE_SX: SxProps<Theme> = {
    '& .MuiTableCell-root': {
        padding: 'var(--space-3) var(--space-2)',
        borderBottom: '1px solid var(--list-table-divider-color)',
        color: 'var(--color-text)',
        fontFamily: 'var(--font-sans)',
        fontSize: 'var(--text-md)',
        verticalAlign: 'middle',
    },
    '& .MuiTableCell-head': {
        padding: 'var(--space-2)',
        color: 'var(--color-text-muted)',
        fontSize: 'var(--text-sm)',
        fontWeight: 'var(--weight-bold)',
        background: 'var(--list-table-head-bg)',
        borderBottom: '1px solid var(--list-table-head-line-color)',
    },
    '& .MuiTableCell-root:first-of-type': {
        paddingLeft: 'var(--space-4)',
    },
    '& .MuiTableCell-root:last-of-type': {
        paddingRight: 'var(--space-4)',
    },
    '& .MuiTableCell-root.list-table-muted': {
        color: 'var(--color-text-muted)',
        fontSize: 'var(--text-sm)',
    },
    '& .MuiTableCell-root.list-table-mono': {
        fontFamily: 'var(--font-mono)',
        fontSize: 'var(--text-sm)',
        overflowWrap: 'anywhere',
    },
    '& .MuiTableBody-root .MuiTableRow-root:last-of-type .MuiTableCell-root': {
        borderBottom: 'none',
    },
    '& .MuiTableBody-root .MuiTableRow-root:nth-of-type(even)': {
        background: 'var(--list-table-stripe-bg)',
    },
    '& .MuiTableBody-root .MuiTableRow-root': {
        transition: 'background-color var(--duration-fast) var(--ease-standard)',
    },
    '& .MuiTableBody-root .MuiTableRow-root:hover': {
        background: 'var(--color-hover)',
    },
    '& .MuiIconButton-root + .MuiIconButton-root': {
        marginLeft: 'var(--space-1)',
    },
    '& .MuiIconButton-root:last-of-type': {
        marginLeft: 'var(--space-3)',
    },
    '& .MuiIconButton-root .MuiSvgIcon-root': {
        fontSize: 'var(--icon-md)',
    },
};
