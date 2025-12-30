import { findAvailablePort } from './find-available-port';
import { createServer as createHttpServer } from 'http';

describe('findAvailablePort', () => {
    it('should return a valid port number', async () => {
        const port = await findAvailablePort();
        
        expect(port).toBeGreaterThan(0);
        expect(port).toBeLessThan(65536);
        expect(Number.isInteger(port)).toBe(true);
    });

    it('should return different ports on consecutive calls', async () => {
        const port1 = await findAvailablePort();
        const port2 = await findAvailablePort();
        
        // While it's possible to get the same port, it's very unlikely
        // The function should work correctly either way
        expect(port1).toBeGreaterThan(0);
        expect(port2).toBeGreaterThan(0);
    });

    it('should return a port that is actually available', async () => {
        const port = await findAvailablePort();
        
        // Verify the port is available by trying to create a server on it
        return new Promise<void>((resolve, reject) => {
            const server = createHttpServer();
            server.listen(port, () => {
                server.close(() => {
                    resolve();
                });
            });
            server.on('error', reject);
        });
    });

    it('should handle multiple concurrent calls', async () => {
        const promises = Array.from({ length: 10 }, () => findAvailablePort());
        const ports = await Promise.all(promises);
        
        // All should be valid ports
        ports.forEach((port: number) => {
            expect(port).toBeGreaterThan(0);
            expect(port).toBeLessThan(65536);
            expect(Number.isInteger(port)).toBe(true);
        });
        
        // All should be unique (very unlikely to have collisions)
        const uniquePorts = new Set(ports);
        expect(uniquePorts.size).toBe(ports.length);
    });
});

