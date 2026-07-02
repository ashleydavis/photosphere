import React from "react";
import { useNavigate } from "react-router-dom";
import Button from "@mui/joy/Button";
import Switch from "@mui/joy/Switch";
import List from "@mui/joy/List/List";
import ListItem from "@mui/joy/ListItem/ListItem";
import ListItemButton from "@mui/joy/ListItemButton/ListItemButton";
import ListItemDecorator from "@mui/joy/ListItemDecorator/ListItemDecorator";
import ListItemContent from "@mui/joy/ListItemContent/ListItemContent";
import { Science, Speed, BugReport } from "@mui/icons-material";
import { useDeveloper } from "../context/developer-context";

//
// A dedicated screen listing developer tools, reachable only while developer
// mode is enabled. New developer tools are added to the list below.
//
export function DeveloperPage(): JSX.Element {
    const navigate = useNavigate();
    const { disableDeveloperMode, showFpsIndicator, toggleShowFpsIndicator, devToolsOpen, toggleDevTools } = useDeveloper();

    return (
        <div data-id="developer-page" className="w-full h-full p-4 overflow-y-auto pb-32">
            <div className="m-auto" style={{ maxWidth: "800px" }}>
                <h1 className="mt-6 text-3xl">Developer</h1>

                <List sx={{ mt: 2 }}>
                    {/* Add future developer tools as additional ListItem entries here. */}
                    <ListItem
                        data-id="developer-tool-stories"
                        onClick={() => navigate("/stories")}
                        >
                        <ListItemButton>
                            <ListItemDecorator><Science /></ListItemDecorator>
                            <ListItemContent>Stories</ListItemContent>
                        </ListItemButton>
                    </ListItem>

                    <ListItem
                        data-id="developer-tool-fps-toggle"
                        onClick={() => toggleShowFpsIndicator()}
                        endAction={
                            <Switch
                                readOnly
                                checked={showFpsIndicator}
                                sx={{ pointerEvents: "none" }}
                                />
                        }
                        >
                        <ListItemButton>
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
                                checked={devToolsOpen}
                                sx={{ pointerEvents: "none" }}
                                />
                        }
                        >
                        <ListItemButton>
                            <ListItemDecorator><BugReport /></ListItemDecorator>
                            <ListItemContent>Developer tools</ListItemContent>
                        </ListItemButton>
                    </ListItem>
                </List>

                <div className="mt-6">
                    <Button
                        data-id="developer-exit"
                        color="neutral"
                        variant="outlined"
                        onClick={() => {
                            disableDeveloperMode();
                            navigate("/gallery");
                        }}
                        >
                        Exit developer mode
                    </Button>
                </div>
            </div>
        </div>
    );
}
