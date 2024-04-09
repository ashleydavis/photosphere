const { app, BrowserWindow, protocol, net } = require('electron');
const path = require('path');

let HTML_PAGE = process.env.HTML_PAGE;
if (!HTML_PAGE) {
    HTML_PAGE = "app://localhost/index.html";
}

//
// Register the app protocol.
//
protocol.registerSchemesAsPrivileged([
    { 
        scheme: 'app', 
        privileges: { corsEnabled: true, standard: true } ,
    }
]);

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

    mainWindow.loadURL(HTML_PAGE);
}

//
// Register a custom protocol. 
// This is required for Auth0 redirection.
//
function registerProtocol() {
    protocol.registerFileProtocol('app', (request, callback) => {
        const [ url, query ] = request.url.split('?');
        let filePath = url.substring('app://localhost/'.length);
        if (filePath == "on_login") {
            filePath = "index.html";
        }
        else if (filePath == "on_logout") {
            filePath = "index.html";
        }

        filePath = `frontend/dist/${filePath}`;

        console.log(`Loading file ${filePath} from url ${request.url}`);

        callback({ path: filePath }); // Maps the URL to a file path.
    });
}

//
// This method will be called when Electron has finished
// initialization and is ready to create browser windows.
// Some APIs can only be used after this event occurs.
//
app.whenReady().then(() => {

    registerProtocol();
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