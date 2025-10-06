//
// Device identification utilities
//

import { machineId } from 'node-machine-id';

//
// Generate a unique device identifier using machine ID
//
export async function generateDeviceId(): Promise<string> {
    // Use machine ID which provides a stable, unique identifier per machine
    const id = await machineId();
    if (!id) {
        throw new Error('Unable to generate device ID: machine ID is empty');
    }
    return id;
}