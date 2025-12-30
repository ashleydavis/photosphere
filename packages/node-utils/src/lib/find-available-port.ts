import { createServer as createHttpServer } from 'http';
import { AddressInfo } from 'net';

//
// Find an available port by creating a temporary server on port 0
//
export async function findAvailablePort(): Promise<number> {
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

