const { app, BrowserWindow } = require('electron');

let HTML_PAGE = process.env.HTML_PAGE;

//
// Creates the browser window.
//
function createWindow() {
    const mainWindow = new BrowserWindow({
        width: 800,
        height: 600,
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false,
        },
    });

    // Open the DevTools.
    mainWindow.webContents.openDevTools();

    if (HTML_PAGE) {
        console.log(`Loading URL ${HTML_PAGE}`);
        mainWindow.loadURL(HTML_PAGE);
    }
    else {
        const filePath = `frontend/dist/index.html`;
        console.log(`Loading file ${filePath}`);
        mainWindow.loadFile(filePath);
    }
}

//
// This method will be called when Electron has finished
// initialization and is ready to create browser windows.
// Some APIs can only be used after this event occurs.
//
app.whenReady().then(() => {

    createWindow()

    app.on('activate', () => {
        //
        // On macOS it's common to re-create a window in the app when the
        // dock icon is clicked and there are no other windows open.
        //
        if (BrowserWindow.getAllWindows().length === 0) {
            createWindow();
        }
    });
})

//
// Quit when all windows are closed, except on macOS. There, it's common
// for applications and their menu bar to stay active until the user quits
// explicitly with Cmd + Q.
//
app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});