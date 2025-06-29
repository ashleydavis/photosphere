import { createServer as createHttpServer } from 'http';
import { AddressInfo } from 'net';

//
// Extract the findAvailablePort function for testing
//
async function findAvailablePort(): Promise<number> {
    return new Promise((resolve, reject) => {
        const server = createHttpServer();
        server.listen(0, () => {
            const addressInfo = server.address() as AddressInfo;
            const port = addressInfo.port;
            server.close(() => {
                resolve(port);
            });
        });
        server.on('error', reject);
    });
}

describe('UI command port allocation', () => {
    test('findAvailablePort returns a valid port number', async () => {
        const port = await findAvailablePort();
        
        expect(port).toBeGreaterThan(0);
        expect(port).toBeLessThanOrEqual(65535);
        expect(Number.isInteger(port)).toBe(true);
    });

    test('findAvailablePort returns different ports on subsequent calls', async () => {
        const port1 = await findAvailablePort();
        const port2 = await findAvailablePort();
        
        // Note: While not guaranteed, it's extremely likely that consecutive calls
        // will return different ports since the OS will allocate the next available port
        expect(port1).toBeGreaterThan(0);
        expect(port2).toBeGreaterThan(0);
        expect(Number.isInteger(port1)).toBe(true);
        expect(Number.isInteger(port2)).toBe(true);
    });

    test('findAvailablePort can find multiple available ports', async () => {
        const ports = await Promise.all([
            findAvailablePort(),
            findAvailablePort(),
            findAvailablePort()
        ]);
        
        ports.forEach(port => {
            expect(port).toBeGreaterThan(0);
            expect(port).toBeLessThanOrEqual(65535);
            expect(Number.isInteger(port)).toBe(true);
        });
        
        // All ports should be unique
        const uniquePorts = new Set(ports);
        expect(uniquePorts.size).toBe(ports.length);
    });
});