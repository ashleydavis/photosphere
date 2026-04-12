import React from "react";
import Box from "@mui/joy/Box";
import Typography from "@mui/joy/Typography";
import Button from "@mui/joy/Button";
import FileUploadIcon from "@mui/icons-material/FileUpload";
import { usePlatform } from "../context/platform-context";

//
// Displayed when a database is open but contains no assets, with a prompt to import photos.
//
export function EmptyDatabase() {
    const { importAssets } = usePlatform();

    return (
        <Box
            className="flex items-center justify-center"
            sx={{
                height: "calc(100vh - 60px)",
            }}
        >
            <Box sx={{ textAlign: "center" }}>
                <Typography level="h4" sx={{ mb: 2 }}>
                    This database contains no photos.
                </Typography>
                <Typography level="body-md" sx={{ mb: 4, maxWidth: 400, mx: "auto" }}>
                    Import photos and videos from your filesystem to get started.
                </Typography>
                <Button
                    variant="soft"
                    color="neutral"
                    size="lg"
                    startDecorator={<FileUploadIcon />}
                    onClick={async () => {
                        await importAssets();
                    }}
                    sx={{
                        borderRadius: "s",
                        px: 4,
                    }}
                >
                    Import photos
                </Button>
            </Box>
        </Box>
    );
}
