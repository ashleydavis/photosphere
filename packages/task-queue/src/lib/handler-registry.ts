//
// Global handler registry that can be accessed by both main thread and workers
//
const handlers = new Map<string, (data: any, workingDirectory: string) => Promise<string>>();

export function registerHandler(type: string, handler: (data: any, workingDirectory: string) => Promise<string>): void {
    handlers.set(type, handler);
}

export function getHandler(type: string): ((data: any, workingDirectory: string) => Promise<string>) | undefined {
    return handlers.get(type);
}

