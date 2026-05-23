import { contextBridge, ipcRenderer, webUtils } from 'electron';
import type { IElectronAPI } from 'electron-defs';

const electronAPI: IElectronAPI = {
    invoke: (channel: string, data?: any): Promise<any> => {
        if (data !== undefined) {
            return ipcRenderer.invoke(channel, data);
        }
        return ipcRenderer.invoke(channel);
    },
    send: (channel: string, data?: any): void => {
        if (data !== undefined) {
            ipcRenderer.send(channel, data);
        }
        else {
            ipcRenderer.send(channel);
        }
    },
    getPathForFile: (file: File): string => {
        return webUtils.getPathForFile(file);
    },
    onMessage: (channel: string, callback: (data: any) => void): void => {
        ipcRenderer.on(channel, (_event, data) => {
            callback(data);
        });
    },
    removeAllListeners: (channel: string): void => {
        ipcRenderer.removeAllListeners(channel);
    },
    log: (message: any): void => {
        ipcRenderer.send('renderer-log', message);
    },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);
