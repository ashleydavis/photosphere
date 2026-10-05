//
// Drives a connected iOS device for the Ziggy example's device smoke tests, through native-run's device library (the
// library Capacitor's `cap run ios` deploys with), so nothing beyond Xcode 14 and the repository's own packages is needed.
//
// It runs under Node rather than Bun because Bun's sockets cannot carry the TLS session native-run starts on a device
// service.
//
// Usage:
//   node scripts/ios-device.ts install <udid> <bundle-id> <app-path>
//       Copies the .app to the device and installs it, replacing any installed copy.
//   node scripts/ios-device.ts launch <udid> <bundle-id> <info-file> [NAME=VALUE...]
//       Launches the installed app under the device's debugserver, stopped at its first instruction, with the given
//       environment. It then listens on a free loopback port and passes one connection through to that debugserver, for
//       lldb to take over the process with `process connect connect://127.0.0.1:<port>`. It writes {"port", "container"}
//       as JSON to <info-file> once it is listening, and exits when either side closes.
//   node scripts/ios-device.ts forward <udid> <device-port> <info-file>
//       Listens on a free loopback port and passes each connection through to <device-port> on the device, over USB.
//       It writes {"port"} as JSON to <info-file> once it is listening, and runs until it is stopped.
//

import { createServer } from "net";
import type { Server, Socket, AddressInfo } from "net";
import { writeFileSync, readFileSync } from "fs";
import { basename, join } from "path";
import nativeRunLib from "native-run/dist/ios/lib/index.js";
import nativeRunXcode from "native-run/dist/ios/utils/xcode.js";

const { ClientManager, UsbmuxdClient, AFCError, AFC_STATUS } = nativeRunLib;

//
// Starts listening on a free loopback port and resolves with that port.
//
function listenOnFreePort(server: Server): Promise<number> {
    return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", () => {
            resolve((server.address() as AddressInfo).port);
        });
    });
}

//
// Passes bytes both ways between two sockets until either closes, then closes the other.
//
function joinSockets(first: Socket, second: Socket): void {
    first.on("data", (data: Buffer) => {
        second.write(data);
    });
    second.on("data", (data: Buffer) => {
        first.write(data);
    });
    first.on("close", () => {
        second.destroy();
    });
    second.on("close", () => {
        first.destroy();
    });
    first.on("error", (error: Error) => {
        console.error(`ios-device: ${error.message}`);
    });
    second.on("error", (error: Error) => {
        console.error(`ios-device: ${error.message}`);
    });
}

//
// Mounts the developer disk image that matches the device's iOS version, which debugserver needs, unless one is mounted.
// This is what native-run does before it launches an app.
//
async function mountDeveloperDiskImage(manager: any): Promise<void> {
    const imageMounter = await manager.getMobileImageMounterClient();
    if ((await imageMounter.lookupImage()).ImageSignature) {
        return;
    }
    const version = await (await manager.getLockdowndClient()).getValue("ProductVersion");
    const imagePath = await nativeRunXcode.getDeveloperDiskImagePath(version);
    const signature = readFileSync(`${imagePath}.signature`);
    await imageMounter.uploadImage(imagePath, signature);
    await imageMounter.mountImage(imagePath, signature);
}

//
// Copies the app into the device's staging directory and installs it from there, as native-run does.
//
async function install(udid: string, bundleId: string, appPath: string): Promise<void> {
    const manager = await ClientManager.create(udid);
    try {
        const afcClient = await manager.getAFCClient();
        try {
            await afcClient.getFileInfo("PublicStaging");
        }
        catch (error: any) {
            if (error instanceof AFCError && error.status === AFC_STATUS.OBJECT_NOT_FOUND) {
                await afcClient.makeDirectory("PublicStaging");
            }
            else {
                throw error;
            }
        }
        const stagedPath = join("PublicStaging", basename(appPath));
        await afcClient.uploadDirectory(appPath, stagedPath);
        const installer = await manager.getInstallationProxyClient();
        await installer.installApp(stagedPath, bundleId);
    }
    finally {
        manager.end();
    }
}

//
// Launches the installed app stopped at its first instruction and hands its debugserver connection to one client.
//
async function launch(udid: string, bundleId: string, infoFile: string, environment: string[]): Promise<void> {
    const manager = await ClientManager.create(udid);
    await mountDeveloperDiskImage(manager);
    const installer = await manager.getInstallationProxyClient();
    const appInfo = (await installer.lookupApp([bundleId]))[bundleId];
    if (!appInfo) {
        throw new Error(`${bundleId} is not installed on ${udid}.`);
    }
    const debugserver = await manager.getDebugserverClient();
    await debugserver.setMaxPacketSize(1024);
    for (const assignment of environment) {
        const environmentResult = await debugserver.sendCommand(`QEnvironmentHexEncoded:${Buffer.from(assignment).toString("hex")}`, []);
        if (environmentResult !== "OK") {
            throw new Error(`debugserver refused the environment ${assignment}: ${environmentResult}`);
        }
    }
    await debugserver.launchApp(appInfo.Path, appInfo.CFBundleExecutable);
    const launchResult = await debugserver.checkLaunchSuccess();
    if (launchResult !== "OK") {
        throw new Error(`debugserver could not launch ${bundleId}: ${launchResult}`);
    }

    // native-run's own reader is detached, so everything debugserver says from here on goes to the client.
    const debugserverSocket: Socket = debugserver.socket;
    debugserverSocket.removeAllListeners("data");
    const server = createServer((client: Socket) => {
        server.close();
        joinSockets(client, debugserverSocket);
        debugserverSocket.on("close", () => {
            manager.end();
        });
    });
    const port = await listenOnFreePort(server);
    writeFileSync(infoFile, JSON.stringify({
        port,
        container: appInfo.Container,
    }));
}

//
// Forwards every connection to a loopback port on to a port on the device.
//
async function forward(udid: string, devicePort: number, infoFile: string): Promise<void> {
    const usbmuxClient = new UsbmuxdClient(UsbmuxdClient.connectUsbmuxdSocket());
    const device = await usbmuxClient.getDevice(udid);
    usbmuxClient.socket.end();
    const server = createServer(async (client: Socket) => {
        client.pause();
        try {
            const deviceSocket: Socket = await new UsbmuxdClient(UsbmuxdClient.connectUsbmuxdSocket()).connect(device, devicePort);
            deviceSocket.removeAllListeners("data");
            joinSockets(client, deviceSocket);
            client.resume();
        }
        catch (error: any) {
            console.error(`ios-device: could not reach port ${devicePort} on ${udid}: ${error.message}`);
            client.destroy();
        }
    });
    const port = await listenOnFreePort(server);
    writeFileSync(infoFile, JSON.stringify({
        port,
    }));
}

//
// Runs the command named on the command line.
//
async function main(): Promise<void> {
    const [command, ...args] = process.argv.slice(2);
    if (command === "install" && args.length === 3) {
        await install(args[0], args[1], args[2]);
    }
    else if (command === "launch" && args.length >= 3) {
        await launch(args[0], args[1], args[2], args.slice(3));
    }
    else if (command === "forward" && args.length === 3) {
        await forward(args[0], Number(args[1]), args[2]);
    }
    else {
        throw new Error("usage: ios-device.ts install <udid> <bundle-id> <app-path> | launch <udid> <bundle-id> <info-file> [NAME=VALUE...] | forward <udid> <device-port> <info-file>");
    }
}

main().catch((error: Error) => {
    console.error(`ios-device: ${error.stack ?? error.message}`);
    process.exit(1);
});
