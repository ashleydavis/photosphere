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
        <Box sx={{ width: '100%', height: '100%', overflowY: 'auto', p: isMobile ? 2 : 4, pb: 16 }}>
            <Box sx={{ mx: 'auto', maxWidth: 800 }}>
                <Typography variant="h2" sx={{ fontSize: isMobile ? '1.75rem' : '2rem', fontWeight: 700, mb: 2 }}>
                    Summary
                </Typography>

                <DatabaseSummaryView />
            </Box>
        </Box>
    );
}
