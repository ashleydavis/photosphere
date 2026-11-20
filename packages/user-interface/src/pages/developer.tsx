import React from "react";
import { useNavigate } from "react-router-dom";
import Box from "@mui/material/Box";
import Card from "@mui/material/Card";
import Button from "@mui/material/Button";
import Switch from "@mui/material/Switch";
import Typography from "@mui/material/Typography";
import List from "@mui/material/List";
import ListItem from "@mui/material/ListItem";
import ListItemButton from "@mui/material/ListItemButton";
import ListItemIcon from "@mui/material/ListItemIcon";
import ListItemText from "@mui/material/ListItemText";
import { Science, Speed, BugReport, ChevronRight, PlayArrow, PlaylistPlay, Layers } from "@mui/icons-material";
import { useDeveloper } from "../context/developer-context";
import { useIsMobile } from "../lib/use-is-mobile";
import { useUuidGenerator } from "../context/uuid-generator-context";
import { planTestJob, startTestJob, TEST_JOB_KINDS } from "../lib/test-jobs";

//
// A dedicated screen listing developer tools, reachable only while developer
// mode is enabled. New developer tools are added to the list below.
//
export function DeveloperPage(): React.JSX.Element {
    const navigate = useNavigate();
    const { disableDeveloperMode, showFpsIndicator, toggleShowFpsIndicator, devToolsOpen, toggleDevTools } = useDeveloper();
    const isMobile = useIsMobile();
    const uuidGenerator = useUuidGenerator();

    //
    // Starts a synthetic job of the given kind, made of the given number of tasks.
    //
    // Each task runs for a random time in the twenty-to-sixty second range, so a grouped job's tasks
    // finish at different moments and the row stays until the last of them is done.
    //
    function startJob(kindIndex: number, taskCount: number): void {
        const randoms = Array.from({ length: taskCount }, () => Math.random());
        startTestJob(uuidGenerator, planTestJob(uuidGenerator.generate(), TEST_JOB_KINDS[kindIndex], taskCount, randoms));
    }

    //
    // Height of each row. Every row is a full-width tap target on a mobile, comfortably above the
    // 48px minimum, because these rows carry switches that are easy to miss with a thumb.
    //
    const rowSx = {
        minHeight: isMobile ? 56 : 44,
        borderRadius: 2,
        px: 1,
    };

    return (
        <Box
            data-id="developer-page"
            sx={{ width: '100%', height: '100%', overflowY: 'auto', p: isMobile ? 2 : 4, pb: 16 }}
            >
            <Box sx={{ mx: 'auto', maxWidth: 800 }}>
                <Typography variant="h2" sx={{ fontSize: isMobile ? '1.75rem' : '2rem', mb: 2 }}>
                    Developer
                </Typography>

                <Card
                    elevation={0}
                    sx={{
                        bgcolor: 'action.hover',
                        borderRadius: 3,
                        p: 1,
                    }}
                    >
                    <List disablePadding>
                        {/* Add future developer tools as additional ListItem entries here. */}
                        <ListItem
                            data-id="developer-tool-stories"
                            disablePadding
                            onClick={() => navigate("/stories")}
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemIcon><Science /></ListItemIcon>
                                <ListItemText primary="Stories" />
                                <ChevronRight sx={{ color: 'text.secondary' }} />
                            </ListItemButton>
                        </ListItem>

                        <ListItem
                            data-id="developer-tool-fps-toggle"
                            onClick={() => toggleShowFpsIndicator()}
                            disablePadding
                            secondaryAction={
                                <Switch
                                    readOnly
                                    size="medium"
                                    checked={showFpsIndicator}
                                    sx={{ pointerEvents: "none" }}
                                    />
                            }
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemIcon><Speed /></ListItemIcon>
                                <ListItemText primary="Show FPS indicator" />
                            </ListItemButton>
                        </ListItem>

                        <ListItem
                            data-id="developer-tool-devtools"
                            onClick={() => toggleDevTools()}
                            disablePadding
                            secondaryAction={
                                <Switch
                                    readOnly
                                    size="medium"
                                    checked={devToolsOpen}
                                    sx={{ pointerEvents: "none" }}
                                    />
                            }
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemIcon><BugReport /></ListItemIcon>
                                <ListItemText primary="Developer tools" />
                            </ListItemButton>
                        </ListItem>
                    </List>
                </Card>

                <Typography variant="subtitle1" sx={{ mt: 3, mb: 1 }}>
                    Test background jobs
                </Typography>
                <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
                    Synthetic work that does nothing but take twenty to sixty seconds, so the background
                    jobs list can be watched and cancelled without staging a database first.
                </Typography>

                <Card
                    elevation={0}
                    sx={{
                        bgcolor: 'action.hover',
                        borderRadius: 3,
                        p: 1,
                    }}
                    >
                    <List disablePadding>
                        {TEST_JOB_KINDS.map((kind, kindIndex) => (
                            <ListItem
                                key={kind.name}
                                data-id={`developer-start-job-${kindIndex}`}
                                disablePadding
                                onClick={() => startJob(kindIndex, 1)}
                                >
                                <ListItemButton sx={rowSx}>
                                    <ListItemIcon><PlayArrow /></ListItemIcon>
                                    <ListItemText primary={kind.name} />
                                </ListItemButton>
                            </ListItem>
                        ))}

                        <ListItem
                            data-id="developer-start-grouped-job"
                            disablePadding
                            onClick={() => startJob(0, 4)}
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemIcon><PlaylistPlay /></ListItemIcon>
                                <ListItemText
                                    primary="One job of four tasks"
                                    secondary="One row that stays until the last of its four tasks finishes."
                                    />
                            </ListItemButton>
                        </ListItem>

                        <ListItem
                            data-id="developer-start-all-jobs"
                            disablePadding
                            onClick={() => TEST_JOB_KINDS.forEach((_kind, kindIndex) => startJob(kindIndex, 1))}
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemIcon><Layers /></ListItemIcon>
                                <ListItemText
                                    primary="All four at once"
                                    secondary="Four separate rows, so the navbar counts them instead of naming one."
                                    />
                            </ListItemButton>
                        </ListItem>
                    </List>
                </Card>

                <Button
                    data-id="developer-exit"
                    color="error"
                    variant="outlined"
                    size={isMobile ? 'large' : 'medium'}
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
