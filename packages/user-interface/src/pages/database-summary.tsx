import React from "react";
import Box from "@mui/material/Box";
import Typography from "@mui/material/Typography";
import { useIsMobile } from "../lib/use-is-mobile";
import { DatabaseSummaryView } from "../components/database-summary-view";

//
// Page that displays summary information about the currently open database.
//
export function DatabaseSummaryPage() {
    const isMobile = useIsMobile();

    return (
        <Box sx={{ width: '100%', height: '100%', overflowY: 'auto' }}>
            <Box
                sx={{
                    display: 'flex',
                    flexDirection: 'column',
                    gap: isMobile ? 'var(--space-4)' : 'var(--space-6)',
                    mx: 'auto',
                    maxWidth: 'calc(var(--space-8) * 30)',
                    padding: isMobile ? 'var(--space-4) var(--space-4) calc(var(--space-8) * 4)' : 'var(--space-6) var(--space-6) calc(var(--space-8) * 4)',
                }}
                >
                <Typography
                    variant="h2"
                    sx={{
                        fontFamily: 'var(--font-heading)',
                        fontSize: 'var(--page-title-size)',
                        fontWeight: 'var(--weight-bold)',
                        lineHeight: 'var(--leading-tight)',
                    }}
                    >
                    Summary
                </Typography>

                <DatabaseSummaryView />
            </Box>
        </Box>
    );
}
