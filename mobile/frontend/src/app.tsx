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
            </div>
        </HashRouter>
    );
}
