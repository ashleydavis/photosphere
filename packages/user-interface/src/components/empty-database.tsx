import React from "react";
import { useNavigate } from "react-router-dom";
import Box from "@mui/joy/Box";
import Typography from "@mui/joy/Typography";
import Button from "@mui/joy/Button";
import AddPhotoAlternateIcon from "@mui/icons-material/AddPhotoAlternate";
import { useIsMobile } from "../lib/use-is-mobile";

//
// Displayed when a database is open but contains no assets, with a prompt to import photos.
//
export function EmptyDatabase() {
    const navigate = useNavigate();

    // Drives the phone layout: a full-width call to action rather than a centred pill.
    const isMobile = useIsMobile();

    return (
        <Box
            sx={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                height: "calc(100vh - 60px)",
                px: isMobile ? 3 : 0,
            }}
        >
            <Box sx={{ textAlign: "center", width: "100%", maxWidth: 420 }}>
                <Box
                    sx={{
                        display: "inline-flex",
                        alignItems: "center",
                        justifyContent: "center",
                        width: isMobile ? 96 : 80,
                        height: isMobile ? 96 : 80,
                        borderRadius: "50%",
                        backgroundColor: "background.level2",
                        mb: 2.5,
                    }}
                    >
                    <AddPhotoAlternateIcon sx={{ fontSize: isMobile ? 48 : 40, color: "text.secondary" }} />
                </Box>

                <Typography level={isMobile ? "h2" : "h4"} sx={{ fontSize: isMobile ? "1.9rem" : undefined, mb: 1.5 }}>
                    No photos yet
                </Typography>
                <Typography level="body-md" sx={{ mb: 4, color: "text.secondary" }}>
                    Import photos and videos to get started.
                </Typography>

                <Button
                    data-id="import-button"
                    variant="solid"
                    color="primary"
                    size="lg"
                    startDecorator={<AddPhotoAlternateIcon />}
                    onClick={() => navigate('/import')}
                    sx={{
                        width: isMobile ? "100%" : undefined,
                        minHeight: 52,
                        borderRadius: "md",
                        px: 4,
                    }}
                >
                    Import photos
                </Button>
            </Box>
        </Box>
    );
}
