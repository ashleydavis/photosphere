import { generateDeviceId } from "node-utils";

//
// Command that returns the device ID.
//
export async function deviceCommand(): Promise<void> {
    const deviceId = await generateDeviceId();
    console.log(deviceId);
}