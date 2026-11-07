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
import { Science, Speed, BugReport, ChevronRight, PlayArrow, PlaylistPlay, Layers } from "@mui/icons-material";
import { useDeveloper } from "../context/developer-context";
import { useIsMobile } from "../lib/use-is-mobile";
import { useUuidGenerator } from "../context/uuid-generator-context";
import { planTestJob, startTestJob, TEST_JOB_KINDS } from "../lib/test-jobs";

//
// A dedicated screen listing developer tools, reachable only while developer
// mode is enabled. New developer tools are added to the list below.
//
export function DeveloperPage(): JSX.Element {
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

                <Typography level="title-md" sx={{ mt: 3, mb: 1 }}>
                    Test background jobs
                </Typography>
                <Typography level="body-sm" color="neutral" sx={{ mb: 1 }}>
                    Synthetic work that does nothing but take twenty to sixty seconds, so the background
                    jobs list can be watched and cancelled without staging a database first.
                </Typography>

                <Card variant="soft" sx={{ borderRadius: 'lg', p: 1, gap: 0 }}>
                    <List sx={{ '--ListItem-paddingX': '8px' }}>
                        {TEST_JOB_KINDS.map((kind, kindIndex) => (
                            <ListItem
                                key={kind.name}
                                data-id={`developer-start-job-${kindIndex}`}
                                onClick={() => startJob(kindIndex, 1)}
                                >
                                <ListItemButton sx={rowSx}>
                                    <ListItemDecorator><PlayArrow /></ListItemDecorator>
                                    <ListItemContent>{kind.name}</ListItemContent>
                                </ListItemButton>
                            </ListItem>
                        ))}

                        <ListItem
                            data-id="developer-start-grouped-job"
                            onClick={() => startJob(0, 4)}
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemDecorator><PlaylistPlay /></ListItemDecorator>
                                <ListItemContent>
                                    One job of four tasks
                                    <Typography level="body-xs" color="neutral" sx={{ display: 'block' }}>
                                        One row that stays until the last of its four tasks finishes.
                                    </Typography>
                                </ListItemContent>
                            </ListItemButton>
                        </ListItem>

                        <ListItem
                            data-id="developer-start-all-jobs"
                            onClick={() => TEST_JOB_KINDS.forEach((_kind, kindIndex) => startJob(kindIndex, 1))}
                            >
                            <ListItemButton sx={rowSx}>
                                <ListItemDecorator><Layers /></ListItemDecorator>
                                <ListItemContent>
                                    All four at once
                                    <Typography level="body-xs" color="neutral" sx={{ display: 'block' }}>
                                        Four separate rows, so the navbar counts them instead of naming one.
                                    </Typography>
                                </ListItemContent>
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
