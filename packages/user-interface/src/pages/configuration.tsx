import React from "react";
import { useColorScheme } from "@mui/joy/styles/CssVarsProvider";
import Stack from "@mui/joy/Stack/Stack";
import Typography from "@mui/joy/Typography/Typography";
import ToggleButtonGroup from "@mui/joy/ToggleButtonGroup/ToggleButtonGroup";
import Button from "@mui/joy/Button/Button";
import Slider from "@mui/joy/Slider/Slider";
import { useConfig } from "../context/config-context";
import { useGalleryLayout } from "../context/gallery-layout-context";

//
// The configuration page for the Photosphere app.
//
export function ConfigurationPage() {
    const { mode, setMode } = useColorScheme();
    const config = useConfig();
    const { targetRowHeight, setTargetRowHeight } = useGalleryLayout();

    return (
        <div className="w-full h-full p-4 overflow-y-auto pb-32">
            <Stack spacing={3} sx={{ maxWidth: 400 }}>
                <Stack>
                    <Typography level="body-xs">Theme</Typography>
                    <ToggleButtonGroup
                        value={mode}
                        onChange={async (_event, value) => {
                            if (value) {
                                const newTheme = value as 'light' | 'dark' | 'system';
                                setMode(newTheme);
                                await config.set("theme", newTheme);
                            }
                        }}
                        sx={{ mt: 1 }}
                    >
                        <Button value="light">Light</Button>
                        <Button value="dark">Dark</Button>
                        <Button value="system">System</Button>
                    </ToggleButtonGroup>
                </Stack>

                <Stack>
                    <Typography level="body-xs">Photo size</Typography>
                    <Slider
                        min={50}
                        max={500}
                        value={targetRowHeight}
                        onChange={(_e, value) => setTargetRowHeight(value as number)}
                    />
                </Stack>
            </Stack>
        </div>
    );
}
