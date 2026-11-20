import React from "react";
import { useNavigate } from "react-router-dom";
import Box from "@mui/material/Box";
import Typography from "@mui/material/Typography";
import Button from "@mui/material/Button";
import AddPhotoAlternateIcon from "@mui/icons-material/AddPhotoAlternate";
import { useIsMobile } from "../lib/use-is-mobile";

//
// Displayed when a database is open but contains no assets, with a prompt to import photos.
//
export function EmptyDatabase() {
    const navigate = useNavigate();

    // Drives the mobile layout: a full-width call to action rather than a centred pill.
    const isMobile = useIsMobile();

    return (
        <Box
            sx={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                height: "100%",
                padding: "var(--space-4)",
            }}
        >
            <Box
                sx={{
                    display: "flex",
                    flexDirection: "column",
                    alignItems: "center",
                    textAlign: "center",
                    gap: "var(--space-3)",
                    width: "100%",
                    maxWidth: "calc(var(--space-8) * 12)",
                }}
            >
                <Box
                    sx={{
                        display: "flex",
                        alignItems: "center",
                        justifyContent: "center",
                        width: "calc(var(--space-8) * 2)",
                        height: "calc(var(--space-8) * 2)",
                        borderRadius: "var(--radius-full)",
                        background: "var(--empty-icon-bg)",
                        color: "var(--color-empty-icon)",
                    }}
                    >
                    <AddPhotoAlternateIcon
                        sx={{
                            fontSize: "var(--space-8)",
                        }}
                        />
                </Box>

                <Typography
                    component="h2"
                    sx={{
                        fontFamily: "var(--font-heading)",
                        fontSize: "var(--text-xl)",
                        fontWeight: "var(--weight-bold)",
                        lineHeight: "var(--leading-tight)",
                        overflowWrap: "anywhere",
                    }}
                    >
                    No photos yet
                </Typography>
                <Typography
                    sx={{
                        color: "var(--color-text-muted)",
                    }}
                    >
                    Import photos and videos to get started.
                </Typography>

                <Button
                    data-id="import-button"
                    variant="contained"
                    color="primary"
                    size="large"
                    startIcon={<AddPhotoAlternateIcon />}
                    onClick={() => navigate('/import')}
                    fullWidth={isMobile}
                    sx={{
                        marginTop: "var(--space-2)",
                    }}
                >
                    Import photos
                </Button>
            </Box>
        </Box>
    );
}
