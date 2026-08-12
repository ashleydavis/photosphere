import React from "react";
import { useColorScheme } from "@mui/joy/styles/CssVarsProvider";
import Box from "@mui/joy/Box";
import Stack from "@mui/joy/Stack/Stack";
import Typography from "@mui/joy/Typography/Typography";
import ToggleButtonGroup from "@mui/joy/ToggleButtonGroup/ToggleButtonGroup";
import Button from "@mui/joy/Button/Button";
import Slider from "@mui/joy/Slider/Slider";
import Card from "@mui/joy/Card";
import { DarkMode, LightMode, SettingsBrightness, PhotoSizeSelectLarge } from "@mui/icons-material";
import { useConfig } from "../context/config-context";
import { useGalleryLayout } from "../context/gallery-layout-context";
import { useIsMobile } from "../lib/use-is-mobile";
import { AutoImportSettings } from "../components/auto-import-settings";

//
// The configuration page for the Photosphere app.
//
// On a phone the settings are grouped into cards, each with a heading and a control sized for a
// thumb: a full-width segmented control for the theme, and a slider with large touch handles for
// the photo size. The desktop layout keeps its narrow, compact column.
//
export function ConfigurationPage() {
    const { mode, setMode } = useColorScheme();
    const config = useConfig();
    const { targetRowHeight, setTargetRowHeight } = useGalleryLayout();
    const isMobile = useIsMobile();

    //
    // Applies the chosen theme and saves it to the config file.
    //
    async function applyTheme(newTheme: 'light' | 'dark' | 'system'): Promise<void> {
        setMode(newTheme);
        await config.set("theme", newTheme);
    }

    return (
        <Box
            sx={{
                width: '100%',
                height: '100%',
                overflowY: 'auto',
                p: isMobile ? 2 : 4,
                pb: 16,
            }}
            >
            {isMobile
                && <Typography level="h2" sx={{ fontSize: '1.75rem', mb: 2 }}>
                    Settings
                </Typography>
            }

            <Stack spacing={2} sx={{ maxWidth: isMobile ? '100%' : 400 }}>
                <Card
                    variant="soft"
                    sx={{ borderRadius: 'lg', p: isMobile ? 2 : 1.5, gap: 1.5 }}
                    >
                    <Typography level="title-md">Theme</Typography>
                    <ToggleButtonGroup
                        value={mode}
                        size={isMobile ? 'lg' : 'md'}
                        onChange={async (_event, value) => {
                            if (value) {
                                await applyTheme(value as 'light' | 'dark' | 'system');
                            }
                        }}
                        // Each option takes an equal share of the full width on a phone, so all
                        // three are the same large, easy target.
                        sx={{ width: '100%', '& > button': { flex: 1, minHeight: isMobile ? 48 : undefined } }}
                        >
                        <Button value="light" startDecorator={<LightMode />}>Light</Button>
                        <Button value="dark" startDecorator={<DarkMode />}>Dark</Button>
                        <Button value="system" startDecorator={<SettingsBrightness />}>System</Button>
                    </ToggleButtonGroup>
                </Card>

                <Card
                    variant="soft"
                    sx={{ borderRadius: 'lg', p: isMobile ? 2 : 1.5, gap: 1.5 }}
                    >
                    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                        <PhotoSizeSelectLarge sx={{ color: 'text.secondary' }} />
                        <Typography level="title-md" sx={{ flexGrow: 1 }}>Photo size</Typography>
                        <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                            {`${targetRowHeight}px`}
                        </Typography>
                    </Box>
                    <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                        How large photos appear in the gallery.
                    </Typography>
                    <Slider
                        min={50}
                        max={500}
                        value={targetRowHeight}
                        size={isMobile ? 'lg' : 'md'}
                        onChange={(_e, value) => setTargetRowHeight(value as number)}
                        // A fat thumb and track: the default is a hard target to hit with a finger.
                        sx={isMobile
                            ? {
                                py: 2,
                                '--Slider-thumbSize': '28px',
                                '--Slider-trackSize': '8px',
                            }
                            : undefined
                        }
                    />
                </Card>

                <AutoImportSettings />
            </Stack>
        </Box>
    );
}
