import React from "react";
import { useNavigate } from "react-router-dom";
import Box from "@mui/joy/Box";
import Card from "@mui/joy/Card";
import Button from "@mui/joy/Button";
import Switch from "@mui/joy/Switch";
import Typography from "@mui/joy/Typography";
import List from "@mui/joy/List/List";
import ListItem from "@mui/joy/ListItem/ListItem";
import ListItemButton from "@mui/joy/ListItemButton/ListItemButton";
import ListItemDecorator from "@mui/joy/ListItemDecorator/ListItemDecorator";
import ListItemContent from "@mui/joy/ListItemContent/ListItemContent";
import { Science, Speed, BugReport, ChevronRight } from "@mui/icons-material";
import { useDeveloper } from "../context/developer-context";
import { useIsMobile } from "../lib/use-is-mobile";

//
// A dedicated screen listing developer tools, reachable only while developer
// mode is enabled. New developer tools are added to the list below.
//
export function DeveloperPage(): JSX.Element {
    const navigate = useNavigate();
    const { disableDeveloperMode, showFpsIndicator, toggleShowFpsIndicator, devToolsOpen, toggleDevTools } = useDeveloper();
    const isMobile = useIsMobile();

    //
    // Height of each row. Every row is a full-width tap target on a phone, comfortably above the
    // 48px minimum, because these rows carry switches that are easy to miss with a thumb.
    //
    const rowSx = { minHeight: isMobile ? 56 : 44, borderRadius: 'md' };

    return (
        <Box
            data-id="developer-page"
            sx={{ width: '100%', height: '100%', overflowY: 'auto', p: isMobile ? 2 : 4, pb: 16 }}
            >
            <Box sx={{ mx: 'auto', maxWidth: 800 }}>
                <Typography level="h2" sx={{ fontSize: isMobile ? '1.75rem' : '2rem', mb: 2 }}>
                    Developer
                </Typography>

                <Card variant="soft" sx={{ borderRadius: 'lg', p: 1, gap: 0 }}>
                    <List sx={{ '--ListItem-paddingX': '8px' }}>
                        {/* Add future developer tools as additional ListItem entries here. */}
                        <ListItem
                            data-id="developer-tool-stories"
                            onClick={() => navigate("/stories")}
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemDecorator><Science /></ListItemDecorator>
                                <ListItemContent>Stories</ListItemContent>
                                <ChevronRight sx={{ color: 'text.tertiary' }} />
                            </ListItemButton>
                        </ListItem>

                        <ListItem
                            data-id="developer-tool-fps-toggle"
                            onClick={() => toggleShowFpsIndicator()}
                            endAction={
                                <Switch
                                    readOnly
                                    size={isMobile ? 'lg' : 'md'}
                                    checked={showFpsIndicator}
                                    sx={{ pointerEvents: "none" }}
                                    />
                            }
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemDecorator><Speed /></ListItemDecorator>
                                <ListItemContent>Show FPS indicator</ListItemContent>
                            </ListItemButton>
                        </ListItem>

                        <ListItem
                            data-id="developer-tool-devtools"
                            onClick={() => toggleDevTools()}
                            endAction={
                                <Switch
                                    readOnly
                                    size={isMobile ? 'lg' : 'md'}
                                    checked={devToolsOpen}
                                    sx={{ pointerEvents: "none" }}
                                    />
                            }
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemDecorator><BugReport /></ListItemDecorator>
                                <ListItemContent>Developer tools</ListItemContent>
                            </ListItemButton>
                        </ListItem>
                    </List>
                </Card>

                <Button
                    data-id="developer-exit"
                    color="danger"
                    variant="soft"
                    size={isMobile ? 'lg' : 'md'}
                    onClick={() => {
                        disableDeveloperMode();
                        navigate("/gallery");
                    }}
                    sx={{
                        mt: 3,
                        width: isMobile ? '100%' : undefined,
                        minHeight: isMobile ? 48 : undefined,
                    }}
                    >
                    Exit developer mode
                </Button>
            </Box>
        </Box>
    );
}
