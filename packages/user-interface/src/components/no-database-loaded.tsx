import React from "react";
import Box from "@mui/joy/Box";
import Typography from "@mui/joy/Typography";
import Button from "@mui/joy/Button";
import FolderOpenIcon from "@mui/icons-material/FolderOpen";
import CreateNewFolderIcon from "@mui/icons-material/CreateNewFolder";
import { useAssetDatabase } from "../context/asset-database-source";

//
// Displayed when no database is loaded, with prompts to create or open one.
//
export function NoDatabaseLoaded() {
    const { selectAndOpenDatabase, selectAndCreateDatabase } = useAssetDatabase();

    return (
        <Box
            className="flex items-center justify-center"
            sx={{
                height: "calc(100vh - 60px)",
            }}
        >
            <Box sx={{ textAlign: 'center' }}>
                <Typography level="h4" sx={{ mb: 2 }}>
                    No database loaded
                </Typography>
                <Typography level="body-md" sx={{ mb: 4, maxWidth: 400, mx: 'auto' }}>
                    Create a new database or open an existing one to start viewing your photos and videos.
                </Typography>
                <Box sx={{ display: 'flex', gap: 2, justifyContent: 'center' }}>
                    <Button
                        variant="soft"
                        color="neutral"
                        size="lg"
                        startDecorator={<CreateNewFolderIcon />}
                        onClick={async () => {
                            await selectAndCreateDatabase();
                        }}
                        sx={{
                            borderRadius: 's',
                            px: 4,
                        }}
                    >
                        Create a database
                    </Button>
                    <Button
                        variant="soft"
                        color="neutral"
                        size="lg"
                        startDecorator={<FolderOpenIcon />}
                        onClick={async () => {
                            await selectAndOpenDatabase();
                        }}
                        sx={{
                            borderRadius: 's',
                            px: 4,
                        }}
                    >
                        Open a database
                    </Button>
                </Box>
            </Box>
        </Box>
    );
}
