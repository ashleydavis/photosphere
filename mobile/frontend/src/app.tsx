import React, { useEffect } from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, CloudGallerySourceContextProvider, GalleryContextProvider, Main, SearchContextProvider, UploadContextProvider } from "user-interface";
import { ComputerPage } from "./pages/computer";
import { ComputerGallerySourceContextProvider } from "./context/source/computer-gallery-source-context";
import { ScanContextProvider } from "./context/scan-context";
import { registerPlugin } from '@capacitor/core';

const FileUploader = registerPlugin<any>('FileUploader'); //TODO: Type me.

export function App() {

    useEffect(() => {
        const backend = process.env.BASE_URL;
        if (!backend) {
            console.error(`BASE_URL environment variable should be set.`);
        }
        else {
            console.log(`BASE_URL environment variable is set to ${backend}`);
        }
        FileUploader.updateSettings({
              backend: backend,
          })
          .catch((err: any) => {
            console.error("Failed to update settings:");
            console.error(err);
          });

        const interval = setInterval(() => {
            FileUploader.getFiles()
                .then(async ({ files }: { files: any[] }) => {
                    for (const file of files) {
                        console.log(`File: ${file.name}`);
                        const { thumbnail } = await FileUploader.loadThumbnail({ path: file.path });
                        console.log(`Thumbnail: ${thumbnail}`);
                    }
                })
                .catch((err: any) => {
                    console.error(`Failed with error:`);
                    console.error(err);
                });

        }, 5000);

        return () => {
            clearInterval(interval);
        };
    }, []);
    return (
        <HashRouter>
            <ApiContextProvider>
                <SearchContextProvider>
                    <CloudGallerySourceContextProvider>
                        <ScanContextProvider>
                            <ComputerGallerySourceContextProvider>
                                <UploadContextProvider>
                                        <Main
                                            computerPage={<ComputerPage />} 
                                            />
                                </UploadContextProvider>
                            </ComputerGallerySourceContextProvider>
                        </ScanContextProvider>
                    </CloudGallerySourceContextProvider>
                </SearchContextProvider>
            </ApiContextProvider>
            <div
                style={{
                    position: "fixed",
                    bottom: 0,
                    right: 0,
                    padding: "1em",
                    color: "white",
                    backgroundColor: "black",
                    width: "200px",
                    height: "200px",                
                }}
                >
                <button 
                    onClick={() => {
                        FileUploader.requestPermissions()
                        .then(() => {
                            return FileUploader.checkPermissions()
                                .then((result: any) => {
                                    if (result.havePermissions) {
                                        console.log("Permissions granted");
                                    }
                                    else {
                                        console.log("Permissions not granted");
                                    }
                                });
                        })
                        .catch((err: any) => {
                            console.error(`Failed with error:`);
                            console.error(err);
                        });    
                    }}
                    >
                    Permissions
                </button>

                <button
                    onClick={() => {
                        FileUploader.startSync()
                            .catch((err: any) => {
                                console.error(`Failed with error:`);
                                console.error(err);
                            });
                    }}
                    >
                    Start Sync
                </button>

                <button
                    onClick={() => {
                        FileUploader.stopSync()
                            .catch((err: any) => {
                                console.error(`Failed with error:`);
                                console.error(err);
                            });
                    }}
                    >
                    Stop Sync
                </button>
            </div>
        </HashRouter>
    );
}
